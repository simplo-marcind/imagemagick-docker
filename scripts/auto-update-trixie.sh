#!/usr/bin/env bash
#
# Skrypt do uruchamiania z crona: aktualizuje Dockerfile.trixie, buduje, testuje i wdraża kontener.
#
# Kroki:
#   1. update-library-versions.sh podmienia wersje ARG w Dockerfile.trixie na najnowsze wydania
#      (ImageMagick, libheif, libaom, libwebp, libjxl),
#   2. jeśli nic się nie zmieniło (i obraz już istnieje) - koniec,
#   3. test-trixie-image.sh buduje obraz kandydujący (tag :candidate) i testuje go
#      na tymczasowym kontenerze (osobny port testowy),
#   4. gdy testy przejdą - obraz dostaje tagi :latest oraz :im-<wersja ImageMagick>,
#      a kontener produkcyjny jest podmieniany i wystawiany na porcie HTTP 3100
#      (poprzedni obraz zostaje pod tagiem :previous),
#   5. gdy nowy kontener nie wstanie - automatyczny rollback do poprzedniego obrazu.
#
# Gdy build/testy/wdrożenie się nie powiodą, Dockerfile.trixie wraca do poprzedniej zawartości,
# a zestaw wersji który zawiódł jest zapamiętany - kolejne uruchomienia crona nie będą
# go budować ponownie, dopóki upstream nie wyda czegoś nowszego (lub użyto --force).
#
# Skrypt nie robi commitów w git - zmieniony Dockerfile.trixie zostaje w katalogu roboczym.
#
# Wymagania: bash, git, docker (użytkownik w grupie docker), curl, flock.
#
# Przykład wpisu w crontab (codziennie o 3:00):
#   0 3 * * * /ścieżka/do/repo/scripts/auto-update-trixie.sh >> /var/log/imagemagick-auto-update.log 2>&1

set -u

usage() {
    cat <<'EOF'
Użycie: auto-update-trixie.sh [opcje]

Opcje:
  -p, --host-port PORT         Port HTTP na hoście dla kontenera produkcyjnego. Domyślnie: 3100
  -t, --test-port PORT         Port na hoście dla kontenera testowego. Domyślnie: 18080
  -i, --image-name NAZWA       Nazwa obrazu (bez tagu). Domyślnie: imagemagick-trixie
  -c, --container-name NAZWA   Nazwa kontenera produkcyjnego. Domyślnie: imagemagick-trixie
  -w, --startup-timeout SEK    Czas oczekiwania na start kontenera produkcyjnego. Domyślnie: 30
  -f, --force                  Buduje, testuje i wdraża nawet bez nowych wersji
                                oraz ponawia zestaw wersji, który wcześniej zawiódł.
  -h, --help                   Wyświetla tę pomoc

Zmienne środowiskowe: STATE_DIR (domyślnie <repo>/.auto-update) - blokada, kopia
Dockerfile i zapamiętany zestaw wersji, który zawiódł.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
DOCKERFILE="$REPO_ROOT/Dockerfile.trixie"
STATE_DIR="${STATE_DIR:-$REPO_ROOT/.auto-update}"

HOST_PORT=3100
TEST_PORT=18080
IMAGE_NAME='imagemagick-trixie'
CONTAINER_NAME='imagemagick-trixie'
STARTUP_TIMEOUT=30
FORCE=0

# Cron ma minimalny PATH - docker/git/curl zwykle leżą w /usr/local/bin.
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin:$PATH"

while [ $# -gt 0 ]; do
    case "$1" in
        -p|--host-port|-t|--test-port|-i|--image-name|-c|--container-name|-w|--startup-timeout)
            [ $# -ge 2 ] || { echo "Opcja $1 wymaga wartości." >&2; exit 2; }
            case "$1" in
                -p|--host-port)       HOST_PORT="$2" ;;
                -t|--test-port)       TEST_PORT="$2" ;;
                -i|--image-name)      IMAGE_NAME="$2" ;;
                -c|--container-name)  CONTAINER_NAME="$2" ;;
                -w|--startup-timeout) STARTUP_TIMEOUT="$2" ;;
            esac
            shift 2 ;;
        -f|--force) FORCE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Nieznana opcja: $1" >&2; usage >&2; exit 2 ;;
    esac
done

for v in HOST_PORT TEST_PORT STARTUP_TIMEOUT; do
    case "${!v}" in
        ''|*[!0-9]*) echo "$v musi być liczbą." >&2; exit 2 ;;
    esac
done

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

for cmd in docker git curl flock; do
    command -v "$cmd" >/dev/null 2>&1 || { log "BŁĄD: nie znaleziono polecenia '$cmd' w PATH."; exit 1; }
done
docker version --format '{{.Server.Version}}' >/dev/null 2>&1 \
    || { log 'BŁĄD: Docker daemon jest niedostępny (brak uprawnień lub nie działa).'; exit 1; }
[ -f "$DOCKERFILE" ] || { log "BŁĄD: brak pliku $DOCKERFILE"; exit 1; }

mkdir -p "$STATE_DIR" || { log "BŁĄD: nie można utworzyć $STATE_DIR"; exit 1; }

# Tylko jedna instancja naraz (build potrafi trwać dłużej niż odstęp między uruchomieniami crona).
exec 9>"$STATE_DIR/lock"
flock -n 9 || { log 'Poprzednie uruchomienie nadal trwa - pomijam.'; exit 0; }

BACKUP="$STATE_DIR/Dockerfile.trixie.bak"
FAILED_FILE="$STATE_DIR/failed-versions"
CANDIDATE_REF="$IMAGE_NAME:candidate"
LATEST_REF="$IMAGE_NAME:latest"
PREVIOUS_REF="$IMAGE_NAME:previous"

RESTORE_DOCKERFILE=0
finish() {
    if [ "$RESTORE_DOCKERFILE" -eq 1 ]; then
        cat "$BACKUP" > "$DOCKERFILE"
        log 'Przywrócono poprzednią zawartość Dockerfile.trixie.'
    fi
}
trap finish EXIT
trap 'log "Przerwano sygnałem."; exit 130' INT TERM

# Linie ARG z wersjami - służą do porównania zestawów wersji.
versions_signature() {
    grep -E '^ARG[[:space:]]+(IM|LIB_HEIF|LIB_AOM|LIB_WEBP|LIBJXL)_VERSION=' "$DOCKERFILE" | tr -d '\r'
}

run_container() {
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
    docker run -d --name "$CONTAINER_NAME" --restart unless-stopped \
        -p "${HOST_PORT}:80" "$LATEST_REF" >/dev/null
}

wait_for_container() {
    local running status start="$SECONDS"
    while [ $((SECONDS - start)) -lt "$STARTUP_TIMEOUT" ]; do
        running="$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)"
        [ "$running" = 'true' ] || return 1
        status="$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://localhost:$HOST_PORT/" 2>/dev/null)"
        [ "$status" = '200' ] && return 0
        sleep 1
    done
    return 1
}

# --- 1. Aktualizacja wersji ---
log 'Sprawdzam nowe wersje bibliotek...'
cp "$DOCKERFILE" "$BACKUP" || { log 'BŁĄD: nie można utworzyć kopii Dockerfile.trixie.'; exit 1; }
RESTORE_DOCKERFILE=1

if ! "$SCRIPT_DIR/update-library-versions.sh" "$DOCKERFILE"; then
    log 'BŁĄD: update-library-versions.sh zakończony błędem.'
    exit 1
fi

CHANGED=1
if cmp -s "$BACKUP" "$DOCKERFILE"; then
    CHANGED=0
    RESTORE_DOCKERFILE=0
fi

if [ "$CHANGED" -eq 0 ] && [ "$FORCE" -eq 0 ] && docker image inspect "$LATEST_REF" >/dev/null 2>&1; then
    log 'Brak nowych wersji - nic do zrobienia.'
    exit 0
fi

NEW_SIGNATURE="$(versions_signature)"

if [ "$CHANGED" -eq 1 ]; then
    log 'Wykryto nowe wersje:'
    diff -u "$BACKUP" "$DOCKERFILE" | grep -E '^[+-]ARG' | sed 's/^/    /'

    if [ "$FORCE" -eq 0 ] && [ -f "$FAILED_FILE" ] && [ "$(cat "$FAILED_FILE")" = "$NEW_SIGNATURE" ]; then
        log 'Ten zestaw wersji już wcześniej zawiódł (build/testy/wdrożenie) - pomijam. Użyj --force, aby ponowić.'
        exit 0
    fi
else
    log 'Brak nowych wersji, ale obraz nie istnieje (lub użyto --force) - buduję aktualny Dockerfile.trixie.'
fi

fail() {
    log "BŁĄD: $1"
    [ "$CHANGED" -eq 0 ] || printf '%s\n' "$NEW_SIGNATURE" > "$FAILED_FILE"
    exit 1
}

# --- 2. Build + testy ---
log "Buduję i testuję obraz '$CANDIDATE_REF' (port testowy $TEST_PORT) - może to potrwać..."
if ! "$SCRIPT_DIR/test-trixie-image.sh" \
        --image-name "$CANDIDATE_REF" \
        --container-name "${CONTAINER_NAME}-test" \
        --host-port "$TEST_PORT"; then
    docker image rm "$CANDIDATE_REF" >/dev/null 2>&1
    fail 'build lub testy obrazu nie powiodły się - Dockerfile.trixie zostaje przywrócony.'
fi
log 'Testy przeszły.'

# --- 3. Wdrożenie ---
IM_VERSION="$(sed -n -E 's/^ARG[[:space:]]+IM_VERSION=([^[:space:]]+).*/\1/p' "$DOCKERFILE" | tr -d '\r' | head -n 1)"

HAD_PREVIOUS=0
PREV_ID="$(docker image inspect -f '{{.Id}}' "$LATEST_REF" 2>/dev/null)"
if [ -n "$PREV_ID" ]; then
    docker tag "$PREV_ID" "$PREVIOUS_REF" && HAD_PREVIOUS=1
fi

docker tag "$CANDIDATE_REF" "$LATEST_REF" || fail "nie udało się otagować $LATEST_REF"
[ -z "$IM_VERSION" ] || docker tag "$CANDIDATE_REF" "$IMAGE_NAME:im-$IM_VERSION"
docker image rm "$CANDIDATE_REF" >/dev/null 2>&1

log "Uruchamiam kontener '$CONTAINER_NAME' na porcie $HOST_PORT..."
if run_container && wait_for_container; then
    log "Wdrożono: http://localhost:$HOST_PORT/ (ImageMagick ${IM_VERSION:-?})."
    rm -f "$FAILED_FILE"
    RESTORE_DOCKERFILE=0
    exit 0
fi

log 'Nowy kontener nie wstał poprawnie. Logi:'
docker logs --tail 30 "$CONTAINER_NAME" 2>&1 | sed 's/^/    /'

if [ "$HAD_PREVIOUS" -eq 1 ]; then
    log 'Rollback do poprzedniego obrazu...'
    docker tag "$PREVIOUS_REF" "$LATEST_REF"
    if run_container && wait_for_container; then
        log 'Rollback zakończony - działa poprzednia wersja.'
    else
        log 'BŁĄD KRYTYCZNY: poprzedni kontener również nie wystartował.'
    fi
else
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
    log 'Brak poprzedniego obrazu do rollbacku - kontener usunięty.'
fi

fail 'wdrożenie nowego kontenera nie powiodło się.'
