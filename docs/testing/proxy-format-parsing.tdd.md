# TDD Evidence — fix generazione squid.conf

Due bug in sequenza, entrambi fatali all'avvio del container.

## Bug 1 — `FATAL: Bungled ... cache_peer`

### Sintomo

```
FATAL: Bungled /etc/squid/squid.conf line 19:
cache_peer 8001 parent  0 no-query round-robin login=johnn_mayY3:...@isp.oxylabs.io
```

### Causa

`generate_squid_conf.sh` usava `IFS=: read -r username password ip port`, che assume il
solo formato `username:password:host:port`. Con il formato URL-style del provider
(`username:password@host:port`, 3 campi separati da `:`) i campi slittano:

| variabile | valore assegnato |
|-----------|------------------|
| `username` | `johnn_mayY3` |
| `password` | `bLcEsNMi6M_3rD@isp.oxylabs.io` |
| `ip`       | `8001` (la porta!) |
| `port`     | *(vuoto)* |

Risultato: `cache_peer <porta> parent <vuoto> 0 ...`. Lo script non validava nulla e
sovrascriveva `squid.conf` comunque, quindi l'errore emergeva solo al boot del container.

### Fix

Parser multi-formato + validazione prima della scrittura, `name=` univoco per peer,
scrittura atomica.

## Bug 2 — `FATAL: Unable to open configuration file: (13) Permission denied`

### Sintomo

Dopo il fix del bug 1, sul server remoto:

```
FATAL: Unable to open configuration file: /etc/squid/squid.conf: (13) Permission denied
```

### Causa

Regressione introdotta dal fix 1. La scrittura atomica usa `mktemp`, che crea i file a
**`0600`**; `mv` è un rename e **conserva i permessi del temporaneo** invece di applicare
la umask. La versione originale usava `cat > squid.conf` e otteneva `0644`. Squid nel
container gira come utente non-root (UID 3128 in `b4tman/squid`) e non poteva più leggere
la config montata dall'host.

### Fix

`chmod 644` sul temporaneo prima del `mv`; il temporaneo viene creato accanto alla
destinazione (rename atomico sullo stesso filesystem).

## User journey

> Come utente, voglio incollare i proxy del provider in `proxy.txt` in un formato comune e
> ottenere una `squid.conf` valida e leggibile dal container — oppure un errore chiaro —
> invece di un container che crasha.

## Task report

| Task | Comando di validazione | Esito |
|------|------------------------|-------|
| Riprodurre il crash `Bungled` in un test | `./tests/test_generate_squid_conf.sh` | **RED** — 19 FAIL / 17 PASS, exit 1 |
| Correggere il parser | `./tests/test_generate_squid_conf.sh` | **GREEN** — 36 PASS / 0 FAIL, exit 0 |
| Riprodurre la regressione permessi (test 14) | `./tests/test_generate_squid_conf.sh` | **RED** — 1 FAIL, `mode attuale: 600` |
| Correggere i permessi | `./tests/test_generate_squid_conf.sh` | **GREEN** — 38 PASS / 0 FAIL, exit 0 |
| Lint | `shellcheck generate_squid_conf.sh` | nessun warning |
| Rigenerazione reale | `./generate_squid_conf.sh` | `(2 proxy upstream)`, `-rw-r--r--` |

Estratto RED bug 1 (test 2, coincide byte per byte con la riga del container):

```
FAIL: host e porta estratti da user:pass@host:port
      | atteso regex: ^cache_peer isp\.oxylabs\.io parent 8001 0 no-query round-robin
      | cache_peer 8001 parent  0 no-query round-robin login=johnn_mayY3:...@isp.oxylabs.io
```

Estratto RED bug 2 (test 14):

```
FAIL: il bit di lettura 'other' e impostato
      | mode attuale: 600 -- squid nel container gira come UID 3128 e non puo leggere il file
```

Estratto GREEN (stessa fixture dopo i fix):

```
cache_peer isp.oxylabs.io parent 8001 0 no-query round-robin name=proxy1 login=johnn_mayY3:...
cache_peer_access proxy1 allow all
```

## Specifica testata

| # | Garanzia | Tipo | Esito |
|---|----------|------|-------|
| 1 | `user:pass:host:port` (formato storico) continua a funzionare | unit | PASS |
| 2 | `user:pass@host:port` produce host e porta corretti | regressione | PASS |
| 3 | Nessun `cache_peer` con porta vuota o con la porta al posto dell'host | regressione | PASS |
| 4 | Stesso host su porte diverse riceve `name=` univoci e una `cache_peer_access` per peer | unit | PASS |
| 5 | Righe vuote e commenti `#` ignorati | unit | PASS |
| 6 | File con line ending CRLF non corrompe la porta | unit | PASS |
| 7 | Riga malformata → exit != 0 con il numero di riga | unit | PASS |
| 8 | Porta non numerica o > 65535 rifiutata | unit | PASS |
| 9 | `squid.conf` esistente preservata se `proxy.txt` è invalido (scrittura atomica) | integrazione | PASS |
| 10 | `proxy.txt` mancante → errore che nomina il file | unit | PASS |
| 11 | Nessun proxy valido → nessuna config vuota generata | unit | PASS |
| 12 | `host:port` senza credenziali → peer senza `login=` | unit | PASS |
| 13 | Direttive base (`http_port`, `never_direct`, `http_access`, `dns_nameservers`) presenti | unit | PASS |
| 14 | La config generata è leggibile dall'utente non-root del container (`o+r`) | regressione | PASS |

## Copertura e gap noti

- Nessun tool di coverage per bash installato (no `kcov`/`bashcov`): la copertura è
  funzionale — tutti i rami di `parse_proxy_line` (formato `@`, 4 campi, 2 campi, formato
  ignoto) e tutti i rami di validazione (host, porta, credenziali, file mancante, zero
  peer, permessi) sono esercitati dai 14 casi sopra.
- **Non verificato in locale**: `squid -k parse` sulla config generata — Docker gira su un
  server remoto. La prova finale resta l'avvio del container. Validazione consigliata sul
  server prima del restart:
  `docker compose run --rm --entrypoint squid squid -k parse -f /etc/squid/squid.conf`
- Il formato `host:port:user:pass` (ordine invertito, usato da alcuni provider) **non** è
  supportato: produce un errore esplicito con il numero di riga, non una config rotta.
- Password contenenti `:` restano ambigue per Squid (`login=user:password` splitta sul
  primo `:`); password contenenti `@` sono invece gestite correttamente.
- I permessi `644` sono espliciti e non rispettano una umask più restrittiva: è
  intenzionale, la config **deve** essere leggibile dall'utente del container.

## Checkpoint

| Stage | Commit |
|-------|--------|
| RED bug 1 | `test: add reproducer for Bungled cache_peer on user:pass@host:port proxies` |
| GREEN bug 1 | `fix: parse user:pass@host:port proxies and validate before writing squid.conf` |
| RED+GREEN bug 2 | `fix: keep generated squid.conf readable by the container squid user` |
| Refactor | non necessario — `shellcheck` pulito, nessuna duplicazione da estrarre |
