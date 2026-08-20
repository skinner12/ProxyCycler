#!/bin/bash
#
# Genera squid.conf a partire dalla lista di proxy upstream in proxy.txt.
#
# Formati di riga supportati (righe vuote e commenti '#' sono ignorati):
#   username:password:host:port        (formato storico)
#   username:password@host:port        (formato URL-style di molti provider)
#   http://username:password@host:port (URL completo, http:// o https://)
#   host:port                          (proxy senza autenticazione)
#
# Una riga non riconosciuta e' un errore fatale: meglio fermarsi qui che
# generare una squid.conf malformata e far crashare il container con
# "FATAL: Bungled squid.conf line N".

set -euo pipefail

PROXY_FILE="${PROXY_FILE:-proxy.txt}"
SQUID_CONF="${SQUID_CONF:-squid.conf}"

readonly PORT_MIN=1
readonly PORT_MAX=65535

die() {
    printf 'ERRORE: %s\n' "$1" >&2
    exit 1
}

# is_valid_port <value>
is_valid_port() {
    case $1 in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge "$PORT_MIN" ] && [ "$1" -le "$PORT_MAX" ]
}

# is_valid_host <value> -- hostname o IP, senza spazi e senza ':'
is_valid_host() {
    case $1 in
        ''|*[[:space:]]*|*:*) return 1 ;;
        *) return 0 ;;
    esac
}

# parse_proxy_line <line>
# Stampa "host<TAB>port<TAB>credentials" (credentials vuoto se assente).
# Ritorna 1 se la riga non e' in nessun formato supportato.
parse_proxy_line() {
    local line=$1
    local credentials='' endpoint='' host='' port=''

    # Rimuove lo schema URL se presente (http://user:pass@host:port)
    line=${line#http://}
    line=${line#https://}

    if [[ $line == *@* ]]; then
        # user:pass@host:port -- l'ultima '@' separa credenziali ed endpoint,
        # cosi' una password contenente '@' non rompe il parsing.
        credentials=${line%@*}
        endpoint=${line##*@}
    else
        local field_count
        field_count=$(awk -F: '{print NF}' <<< "$line")
        case $field_count in
            4)
                # username:password:host:port
                credentials="${line%:*:*}"
                endpoint="${line#*:*:}"
                ;;
            2)
                # host:port, nessuna autenticazione
                endpoint=$line
                ;;
            *)
                return 1
                ;;
        esac
    fi

    host=${endpoint%:*}
    port=${endpoint##*:}

    is_valid_host "$host" || return 1
    is_valid_port "$port" || return 1
    if [ -n "$credentials" ]; then
        # Squid vuole esattamente login=user:password
        [[ $credentials == *:* ]] || return 1
        case $credentials in *[[:space:]]*) return 1 ;; esac
    fi

    printf '%s\t%s\t%s\n' "$host" "$port" "$credentials"
}

# --- validazione input -------------------------------------------------------

[ -f "$PROXY_FILE" ] || die "$PROXY_FILE non trovato nella directory corrente ($PWD)."
[ -r "$PROXY_FILE" ] || die "$PROXY_FILE non e' leggibile."

# --- parsing (prima di scrivere qualsiasi cosa) ------------------------------

peer_directives=''
peer_count=0
line_number=0

while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    line_number=$((line_number + 1))

    # Normalizza: via il CR dei file salvati su Windows, via spazi ai bordi
    line=${raw_line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}

    [ -z "$line" ] && continue
    case $line in '#'*) continue ;; esac

    if ! parsed=$(parse_proxy_line "$line"); then
        die "$PROXY_FILE riga $line_number: formato non riconosciuto.
       Formati supportati: username:password:host:port | username:password@host:port | host:port"
    fi

    IFS=$'\t' read -r host port credentials <<< "$parsed"

    peer_count=$((peer_count + 1))
    peer_name="proxy${peer_count}"

    # name= rende univoco ogni peer: senza, due porte dello stesso host
    # (tipico dei provider ISP) darebbero "cache_peer specified twice".
    peer_line="cache_peer $host parent $port 0 no-query round-robin name=$peer_name"
    [ -n "$credentials" ] && peer_line="$peer_line login=$credentials"

    peer_directives="${peer_directives}${peer_line}
cache_peer_access $peer_name allow all
"
done < "$PROXY_FILE"

[ "$peer_count" -gt 0 ] || die "$PROXY_FILE non contiene nessun proxy valido: squid.conf non generata."

# --- scrittura (atomica: la config precedente sopravvive a un errore) --------

# Il file temporaneo vive accanto alla destinazione: il mv finale e' quindi un
# rename atomico sullo stesso filesystem (niente copia cross-device).
tmp_conf=$(mktemp "${SQUID_CONF}.XXXXXX") || die "impossibile creare un file temporaneo accanto a $SQUID_CONF"
trap 'rm -f "$tmp_conf"' EXIT

cat > "$tmp_conf" <<EOL
# Port on which Squid listens
http_port 3128

# Fix DNS socket for non-root user (b4tman/squid runs as UID 3128)
# Forces IPv4 binding to avoid "Permission denied" on DNS socket creation
udp_outgoing_address 0.0.0.0

# Explicit DNS servers (avoids container DNS resolution issues)
dns_nameservers 8.8.8.8 1.1.1.1

# Limit the memory used for cache in RAM
cache_mem 32 MB

# Disable disk cache (optional)
# If you don't want to use disk cache, comment or remove this line
# cache_dir ufs /var/spool/squid 100 16 256

# List of external proxies with round-robin rotation
${peer_directives}
# Allow traffic through the external proxies
# Block direct access
never_direct allow all

# Allow HTTP access
http_access allow all

# Logs
access_log /var/log/squid/access.log squid
cache_log /var/log/squid/cache.log

# Directory for core dumps (use existing directory in container)
coredump_dir /tmp
EOL

# mktemp crea il file con permessi 0600. Squid gira come utente non-root
# (UID 3128 nell'immagine b4tman/squid) e deve poter leggere la config montata
# dall'host: senza questo chmod il container muore con
# "FATAL: Unable to open configuration file: /etc/squid/squid.conf: (13) Permission denied".
chmod 644 "$tmp_conf"

mv "$tmp_conf" "$SQUID_CONF"
trap - EXIT

printf 'File %s generato con successo (%d proxy upstream).\n' "$SQUID_CONF" "$peer_count"
