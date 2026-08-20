#!/usr/bin/env bash
# Test suite for generate_squid_conf.sh
#
# Each test runs the generator inside an isolated temp dir so the real
# proxy.txt / squid.conf are never touched.
#
# Usage: ./tests/test_generate_squid_conf.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATOR="$REPO_DIR/generate_squid_conf.sh"

PASS_COUNT=0
FAIL_COUNT=0

# --- assertion helpers -------------------------------------------------------

pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf '  PASS: %s\n' "$1"; }

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '  FAIL: %s\n' "$1"
    [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        | /'
    return 0
}

# assert_grep <file> <extended-regex> <description>
assert_grep() {
    local file=$1 pattern=$2 desc=$3
    if [ -f "$file" ] && grep -Eq -- "$pattern" "$file"; then
        pass "$desc"
    else
        fail "$desc" "atteso regex: $pattern
--- contenuto generato ---
$( [ -f "$file" ] && cat "$file" || echo '(file inesistente)')"
    fi
}

# assert_not_grep <file> <extended-regex> <description>
assert_not_grep() {
    local file=$1 pattern=$2 desc=$3
    if [ -f "$file" ] && grep -Eq -- "$pattern" "$file"; then
        fail "$desc" "regex NON attesa trovata: $pattern
--- contenuto generato ---
$(cat "$file")"
    else
        pass "$desc"
    fi
}

# assert_eq <actual> <expected> <description>
assert_eq() {
    if [ "$1" = "$2" ]; then pass "$3"; else fail "$3" "atteso: '$2' -- ottenuto: '$1'"; fi
}

# assert_ne <actual> <not-expected> <description>
assert_ne() {
    if [ "$1" != "$2" ]; then pass "$3"; else fail "$3" "valore non atteso: '$2'"; fi
}

describe() { printf '\n%s\n' "$1"; }

# --- generator runner --------------------------------------------------------

# run_generator <proxy-file-content>
# Sets: WORKDIR, CONF (path to generated squid.conf), STATUS, STDERR_OUT
run_generator() {
    WORKDIR="$(mktemp -d)"
    printf '%s' "$1" > "$WORKDIR/proxy.txt"
    CONF="$WORKDIR/squid.conf"
    STDERR_OUT="$( cd "$WORKDIR" && bash "$GENERATOR" 2>&1 >/dev/null )"
    STATUS=$?
    return 0
}

# =============================================================================
# TESTS
# =============================================================================

describe "1. formato legacy user:pass:ip:port genera un peer valido"
run_generator 'alice:s3cret:203.0.113.10:3128
'
assert_eq "$STATUS" "0" "esce con codice 0"
assert_grep "$CONF" '^cache_peer 203\.0\.113\.10 parent 3128 0 no-query round-robin' "cache_peer con host e porta corretti"
assert_grep "$CONF" 'login=alice:s3cret' "credenziali propagate in login="

describe "2. formato user:pass@host:port (Oxylabs) genera un peer valido -- REGRESSIONE del crash Bungled"
run_generator 'johnn_mayY3:bLcEsNMi6M_3rD@isp.oxylabs.io:8001
'
assert_eq "$STATUS" "0" "esce con codice 0"
assert_grep "$CONF" '^cache_peer isp\.oxylabs\.io parent 8001 0 no-query round-robin' "host e porta estratti da user:pass@host:port"
assert_grep "$CONF" 'login=johnn_mayY3:bLcEsNMi6M_3rD$' "login= contiene solo user:pass, non l host"

describe "3. nessuna riga cache_peer con porta vuota (guardia anti-Bungled)"
run_generator 'johnn_mayY3:bLcEsNMi6M_3rD@isp.oxylabs.io:8001
alice:s3cret:203.0.113.10:3128
'
assert_not_grep "$CONF" '^cache_peer [^ ]+ parent ( |$)' "nessun cache_peer con campo porta vuoto"
assert_not_grep "$CONF" '^cache_peer [0-9]+ parent' "nessun cache_peer che usa la porta come hostname"

describe "4. stesso host con porte diverse riceve nomi peer univoci"
run_generator 'user1:pass1@isp.oxylabs.io:8001
user2:pass2@isp.oxylabs.io:8002
'
assert_eq "$STATUS" "0" "esce con codice 0"
assert_grep "$CONF" '^cache_peer isp\.oxylabs\.io parent 8001 .*name=' "primo peer ha un name="
assert_grep "$CONF" '^cache_peer isp\.oxylabs\.io parent 8002 .*name=' "secondo peer ha un name="
PEER_NAMES=$(grep -Eo 'name=[^ ]+' "$CONF" 2>/dev/null | sort)
UNIQUE_NAMES=$(printf '%s\n' "$PEER_NAMES" | sort -u)
assert_eq "$(printf '%s\n' "$PEER_NAMES" | wc -l | tr -d ' ')" "$(printf '%s\n' "$UNIQUE_NAMES" | wc -l | tr -d ' ')" "i name= dei peer sono univoci"
ACCESS_COUNT=$(grep -c '^cache_peer_access ' "$CONF" 2>/dev/null || echo 0)
assert_eq "$ACCESS_COUNT" "2" "una direttiva cache_peer_access per peer"
DUP_ACCESS=$(grep '^cache_peer_access ' "$CONF" 2>/dev/null | sort | uniq -d | wc -l | tr -d ' ')
assert_eq "$DUP_ACCESS" "0" "nessuna cache_peer_access duplicata"

describe "5. righe vuote e commenti vengono ignorati"
run_generator '# proxy del provider
alice:s3cret:203.0.113.10:3128

  # commento indentato

bob:hunter2:203.0.113.11:3129
'
assert_eq "$STATUS" "0" "esce con codice 0"
assert_eq "$(grep -c '^cache_peer ' "$CONF" 2>/dev/null || echo 0)" "2" "generati esattamente 2 peer"
assert_not_grep "$CONF" '^cache_peer +parent' "nessun peer generato da riga vuota"

describe "6. line ending CRLF non corrompe la porta"
run_generator "$(printf 'alice:s3cret:203.0.113.10:3128\r\n')"
assert_eq "$STATUS" "0" "esce con codice 0"
assert_grep "$CONF" '^cache_peer 203\.0\.113\.10 parent 3128 0 ' "porta pulita dal carriage return"
assert_not_grep "$CONF" $'\r' "nessun carriage return nella config generata"

describe "7. riga malformata fa fallire il generatore con errore chiaro"
run_generator 'alice:s3cret:203.0.113.10
'
assert_ne "$STATUS" "0" "esce con codice diverso da 0"
case "$STDERR_OUT" in
    *1*) pass "il messaggio d errore indica il numero di riga" ;;
    *) fail "il messaggio d errore indica il numero di riga" "stderr: $STDERR_OUT" ;;
esac

describe "8. porta non numerica o fuori range viene rifiutata"
run_generator 'alice:s3cret:203.0.113.10:notaport
'
assert_ne "$STATUS" "0" "porta non numerica rifiutata"
run_generator 'alice:s3cret:203.0.113.10:99999
'
assert_ne "$STATUS" "0" "porta fuori range (>65535) rifiutata"

describe "9. una squid.conf esistente non viene distrutta se proxy.txt e invalido"
WORKDIR="$(mktemp -d)"
printf 'alice:s3cret:203.0.113.10\n' > "$WORKDIR/proxy.txt"
printf 'SENTINELLA CONFIG PRECEDENTE\n' > "$WORKDIR/squid.conf"
( cd "$WORKDIR" && bash "$GENERATOR" >/dev/null 2>&1 )
STATUS=$?
assert_ne "$STATUS" "0" "esce con codice diverso da 0"
assert_grep "$WORKDIR/squid.conf" '^SENTINELLA CONFIG PRECEDENTE$' "la config precedente e preservata"

describe "10. proxy.txt mancante produce un errore esplicito"
WORKDIR="$(mktemp -d)"
STDERR_OUT="$( cd "$WORKDIR" && bash "$GENERATOR" 2>&1 >/dev/null )"
STATUS=$?
assert_ne "$STATUS" "0" "esce con codice diverso da 0"
case "$STDERR_OUT" in
    *proxy.txt*) pass "il messaggio d errore nomina proxy.txt" ;;
    *) fail "il messaggio d errore nomina proxy.txt" "stderr: $STDERR_OUT" ;;
esac

describe "11. proxy.txt senza nessun proxy valido non genera una config vuota"
run_generator '# solo commenti

'
assert_ne "$STATUS" "0" "esce con codice diverso da 0 quando non c e nessun proxy"

describe "12. formato host:port senza autenticazione e supportato"
run_generator '203.0.113.10:3128
'
assert_eq "$STATUS" "0" "esce con codice 0"
assert_grep "$CONF" '^cache_peer 203\.0\.113\.10 parent 3128 0 no-query round-robin' "peer senza credenziali generato"
assert_not_grep "$CONF" 'login=' "nessuna direttiva login= per peer senza credenziali"

describe "13. le direttive di base restano presenti"
run_generator 'alice:s3cret:203.0.113.10:3128
'
assert_grep "$CONF" '^http_port 3128$' "http_port presente"
assert_grep "$CONF" '^never_direct allow all$' "never_direct presente"
assert_grep "$CONF" '^http_access allow all$' "http_access presente"
assert_grep "$CONF" '^dns_nameservers ' "dns_nameservers presente"

# =============================================================================

printf '\n============================================\n'
printf 'PASS: %d   FAIL: %d\n' "$PASS_COUNT" "$FAIL_COUNT"
printf '============================================\n'
[ "$FAIL_COUNT" -eq 0 ] || exit 1
exit 0
