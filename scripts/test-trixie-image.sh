#!/usr/bin/env bash
#
# Buduje obraz z Dockerfile.trixie, uruchamia kontener i testuje serwer konwersji do JPG po HTTP.
#
# Kroki:
#   1. docker build -f Dockerfile.trixie (można pominąć przez --skip-build),
#   2. docker run - start kontenera z serwerem (port 80 w kontenerze mapowany na --host-port),
#   3. oczekiwanie na gotowość serwera (GET /),
#   4. dla każdego pliku z katalogu testowego: POST multipart na /convert,
#      a następnie sprawdzenie, że odpowiedź to 200, Content-Type image/jpeg,
#      dane zaczynają się od sygnatury JPEG (FF D8 FF) i - po przekazaniu do kontenera -
#      `magick identify` rozpoznaje je jako JPEG,
#   5. testy negatywne (plik niebędący obrazem -> 415, nieprawidłowy parametr quality -> 400),
#   6. sprzątanie (zatrzymanie i usunięcie kontenera; można zostawić przez --keep-container).
#
# Skrypt kończy się kodem 0, gdy wszystkie testy przeszły, w przeciwnym razie kodem 1.
#
# Wymagania: bash, docker (działający daemon), curl.
# Działa w Linux, macOS oraz Git Bash / WSL w Windows.

set -u

usage() {
    cat <<'EOF'
Użycie: test-trixie-image.sh [opcje]

Opcje:
  -i, --image-name NAZWA        Nazwa (tag) budowanego obrazu.
                                Domyślnie: imagemagick-trixie-test
  -c, --container-name NAZWA    Nazwa uruchamianego kontenera.
                                Domyślnie: imagemagick-trixie-test
  -p, --host-port PORT          Port na hoście mapowany na port 80 w kontenerze.
                                Domyślnie: 18080
  -t, --test-images-path DIR    Katalog z plikami testowymi.
                                Domyślnie: test-images w korzeniu repozytorium
  -o, --output-path DIR         Katalog, do którego zapisywane są wyniki konwersji (JPG).
                                Domyślnie: katalog tymczasowy
  -s, --skip-build              Pomija docker build i używa istniejącego obrazu --image-name
  -n, --no-cache                Przekazuje --no-cache do docker build
  -k, --keep-container          Nie zatrzymuje ani nie usuwa kontenera po testach
  -w, --startup-timeout SEK     Maksymalny czas oczekiwania na start serwera (sekundy).
                                Domyślnie: 30
  -h, --help                    Wyświetla tę pomoc

Przykłady:
  ./test-trixie-image.sh
  ./test-trixie-image.sh --skip-build --host-port 8080 --keep-container
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

IMAGE_NAME='imagemagick-trixie-test'
CONTAINER_NAME='imagemagick-trixie-test'
HOST_PORT=18080
TEST_IMAGES_PATH=''
OUTPUT_PATH=''
SKIP_BUILD=0
NO_CACHE=0
KEEP_CONTAINER=0
STARTUP_TIMEOUT=30

need_value() {
    if [ "$2" -lt 2 ]; then
        echo "Opcja $1 wymaga wartości." >&2
        exit 2
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        -i|--image-name)        need_value "$1" $#; IMAGE_NAME="$2"; shift 2 ;;
        -c|--container-name)    need_value "$1" $#; CONTAINER_NAME="$2"; shift 2 ;;
        -p|--host-port)         need_value "$1" $#; HOST_PORT="$2"; shift 2 ;;
        -t|--test-images-path)  need_value "$1" $#; TEST_IMAGES_PATH="$2"; shift 2 ;;
        -o|--output-path)       need_value "$1" $#; OUTPUT_PATH="$2"; shift 2 ;;
        -s|--skip-build)        SKIP_BUILD=1; shift ;;
        -n|--no-cache)          NO_CACHE=1; shift ;;
        -k|--keep-container)    KEEP_CONTAINER=1; shift ;;
        -w|--startup-timeout)   need_value "$1" $#; STARTUP_TIMEOUT="$2"; shift 2 ;;
        -h|--help)              usage; exit 0 ;;
        *) echo "Nieznana opcja: $1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$HOST_PORT" in
    ''|*[!0-9]*) echo "--host-port musi być liczbą z zakresu 1-65535." >&2; exit 2 ;;
esac
if [ "$HOST_PORT" -lt 1 ] || [ "$HOST_PORT" -gt 65535 ]; then
    echo "--host-port musi być liczbą z zakresu 1-65535." >&2
    exit 2
fi
case "$STARTUP_TIMEOUT" in
    ''|*[!0-9]*) echo "--startup-timeout musi być liczbą z zakresu 1-600." >&2; exit 2 ;;
esac
if [ "$STARTUP_TIMEOUT" -lt 1 ] || [ "$STARTUP_TIMEOUT" -gt 600 ]; then
    echo "--startup-timeout musi być liczbą z zakresu 1-600." >&2
    exit 2
fi

[ -n "$TEST_IMAGES_PATH" ] || TEST_IMAGES_PATH="$REPO_ROOT/test-images"
[ -n "$OUTPUT_PATH" ] || OUTPUT_PATH="${TMPDIR:-/tmp}/imagemagick-trixie-test"
OUTPUT_PATH="${OUTPUT_PATH%/}"

# Git Bash (MSYS) nie powinien przerabiać argumentów typu /tmp/... przekazywanych do dockera.
export MSYS_NO_PATHCONV=1

BASE_URL="http://localhost:$HOST_PORT"
PASSED=0
FAILED=0
CONTAINER_STARTED=0
WORK_DIR=''
CLEANED_UP=0

if [ -t 1 ]; then
    C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_RESET=$'\033[0m'
else
    C_CYAN=''; C_GREEN=''; C_RED=''; C_YELLOW=''; C_RESET=''
fi

write_step() {
    echo
    echo "${C_CYAN}==> $1${C_RESET}"
}

# write_result <ok:0|1> <nazwa> <szczegóły>
write_result() {
    if [ "$1" -eq 1 ]; then
        PASSED=$((PASSED + 1))
        printf '  %s[PASS] %-26s %s%s\n' "$C_GREEN" "$2" "$3" "$C_RESET"
    else
        FAILED=$((FAILED + 1))
        printf '  %s[FAIL] %-26s %s%s\n' "$C_RED" "$2" "$3" "$C_RESET"
    fi
}

# Rozmiar pliku w bajtach.
file_size() {
    wc -c < "$1" | tr -d '[:space:]'
}

# Ścieżka zrozumiała dla natywnego curl (w Git Bash na Windows: /d/foo -> D:/foo).
native_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        printf '%s' "$1"
    fi
}

# Wysyła plik jako multipart/form-data (pole "file") na /convert.
# Użycie: send_upload <plik> <nazwa_pliku> <plik_wyjściowy> [pole=wartość ...]
# Ustawia: UP_STATUS (kod HTTP, 000 przy błędzie połączenia), UP_CTYPE (Content-Type bez parametrów).
send_upload() {
    local file="$1" fname="$2" body="$3"
    shift 3
    local args=() field out nfile nbody
    nfile="$(native_path "$file")"
    nbody="$(native_path "$body")"
    for field in "$@"; do
        args+=(-F "$field")
    done

    UP_STATUS=000
    UP_CTYPE=''
    : > "$body"
    out="$(curl -sS -m 180 -o "$nbody" -w '%{http_code}|%{content_type}' \
        -F "file=@${nfile};filename=${fname}" "${args[@]+"${args[@]}"}" \
        "$BASE_URL/convert" 2>/dev/null)" || true

    UP_STATUS="${out%%|*}"
    UP_CTYPE="${out#*|}"
    UP_CTYPE="${UP_CTYPE%%;*}"
    [ -n "$UP_STATUS" ] || UP_STATUS=000
}

wait_for_server() {
    local running status start="$SECONDS"
    while [ $((SECONDS - start)) -lt "$STARTUP_TIMEOUT" ]; do
        running="$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)"
        if [ "$running" != 'true' ]; then
            echo 'Kontener zakończył działanie przed startem serwera.' >&2
            return 1
        fi
        status="$(curl -s -m 2 -o /dev/null -w '%{http_code}' "$BASE_URL/" 2>/dev/null)"
        if [ "$status" = '200' ]; then
            return 0
        fi
        sleep 0.5
    done
    echo "Serwer nie odpowiedział w ciągu ${STARTUP_TIMEOUT} s." >&2
    return 1
}

test_converted_file() {
    local file="$1"
    local name base ext body_file out_file identify size sig w h
    name="$(basename "$file")"
    base="${name%.*}"
    ext="${name##*.}"
    body_file="$WORK_DIR/body.bin"

    send_upload "$file" "$name" "$body_file"

    if [ "$UP_STATUS" = '000' ]; then
        write_result 0 "$name" 'błąd żądania HTTP (brak odpowiedzi serwera)'
        return
    fi
    if [ "$UP_STATUS" != '200' ]; then
        write_result 0 "$name" "HTTP $UP_STATUS: $(head -c 300 "$body_file" | tr '\r\n' '  ')"
        return
    fi
    if [ "$UP_CTYPE" != 'image/jpeg' ]; then
        write_result 0 "$name" "Content-Type '$UP_CTYPE' zamiast image/jpeg"
        return
    fi

    sig="$(head -c 3 "$body_file" | od -An -tx1 | tr -d ' \n')"
    if [ "$sig" != 'ffd8ff' ]; then
        write_result 0 "$name" 'odpowiedź nie ma sygnatury JPEG (FF D8 FF)'
        return
    fi

    out_file="$OUTPUT_PATH/${base}-${ext}.jpg"
    cp "$body_file" "$out_file"
    size="$(file_size "$out_file")"

    # Niezależna weryfikacja formatu i wymiarów przez ImageMagick w kontenerze (dane przez stdin).
    identify="$(docker exec -i "$CONTAINER_NAME" magick identify -format '%m %w %h' - < "$out_file" 2>/dev/null)"
    if ! [[ "$identify" =~ ^JPEG\ ([0-9]+)\ ([0-9]+)$ ]]; then
        write_result 0 "$name" "magick identify nie rozpoznał JPEG: '$identify'"
        return
    fi
    w="${BASH_REMATCH[1]}"
    h="${BASH_REMATCH[2]}"

    write_result 1 "$name" "-> ${w}x${h} JPEG, ${size} B"
}

cleanup() {
    [ "$CLEANED_UP" -eq 0 ] || return
    CLEANED_UP=1
    if [ "$CONTAINER_STARTED" -eq 1 ] && [ "$KEEP_CONTAINER" -eq 0 ]; then
        write_step "Usuwanie kontenera '$CONTAINER_NAME'"
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
    fi
    [ -z "$WORK_DIR" ] || rm -rf "$WORK_DIR"
}

on_exit() {
    cleanup
    echo
    echo "Wyniki: $PASSED OK, $FAILED błędów. Pliki JPG: $OUTPUT_PATH"
    if [ "$FAILED" -gt 0 ]; then
        exit 1
    fi
    exit 0
}

# Błąd krytyczny: komunikat, logi kontenera, a następnie sprzątanie i podsumowanie (w on_exit).
die() {
    FAILED=$((FAILED + 1))
    echo
    echo "${C_RED}BŁĄD: $1${C_RESET}"
    if [ "$CONTAINER_STARTED" -eq 1 ]; then
        echo "${C_YELLOW}--- logi kontenera ---${C_RESET}"
        docker logs --tail 50 "$CONTAINER_NAME"
    fi
    exit 1
}

trap on_exit EXIT
trap 'FAILED=$((FAILED + 1)); exit 130' INT TERM

command -v docker >/dev/null 2>&1 || die 'Nie znaleziono polecenia "docker" w PATH.'
command -v curl >/dev/null 2>&1 || die 'Nie znaleziono polecenia "curl" w PATH.'

docker version --format '{{.Server.Version}}' >/dev/null 2>&1 || die 'Docker daemon jest niedostępny.'

[ -d "$TEST_IMAGES_PATH" ] || die "Brak katalogu z plikami testowymi: $TEST_IMAGES_PATH"

TEST_FILES=()
for f in "$TEST_IMAGES_PATH"/*; do
    [ -f "$f" ] && TEST_FILES+=("$f")
done
[ "${#TEST_FILES[@]}" -gt 0 ] || die "Katalog $TEST_IMAGES_PATH nie zawiera plików."

rm -rf "$OUTPUT_PATH"
mkdir -p "$OUTPUT_PATH" || die "Nie można utworzyć katalogu $OUTPUT_PATH"
WORK_DIR="$(mktemp -d)" || die 'Nie można utworzyć katalogu tymczasowego.'

# --- 1. Build ---
if [ "$SKIP_BUILD" -eq 1 ]; then
    write_step "Pomijam build, używam obrazu '$IMAGE_NAME'"
    docker image inspect "$IMAGE_NAME" >/dev/null 2>&1 \
        || die "Obraz '$IMAGE_NAME' nie istnieje - uruchom bez --skip-build."
else
    write_step "Budowanie obrazu '$IMAGE_NAME' (Dockerfile.trixie)"
    BUILD_ARGS=(build -f Dockerfile.trixie -t "$IMAGE_NAME")
    [ "$NO_CACHE" -eq 0 ] || BUILD_ARGS+=(--no-cache)
    BUILD_ARGS+=(.)
    # Ścieżki względne od korzenia repozytorium - działają także w Git Bash na Windows.
    (cd "$REPO_ROOT" && docker "${BUILD_ARGS[@]}") || die "docker ${BUILD_ARGS[*]} zakończone błędem"
fi

# --- 2. Run ---
write_step "Start kontenera '$CONTAINER_NAME' na porcie $HOST_PORT"
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
docker run -d --name "$CONTAINER_NAME" -p "${HOST_PORT}:80" "$IMAGE_NAME" >/dev/null \
    || die "docker run zakończone błędem"
CONTAINER_STARTED=1

write_step 'Oczekiwanie na gotowość serwera'
wait_for_server || die 'Serwer nie jest gotowy.'
echo "  ${C_GREEN}Serwer odpowiada na $BASE_URL/${C_RESET}"

# --- 3. Testy konwersji ---
write_step "Konwersja plików z '$TEST_IMAGES_PATH' do JPG"
for f in "${TEST_FILES[@]}"; do
    test_converted_file "$f"
done

# --- 4. Testy negatywne ---
write_step 'Testy negatywne'
BODY="$WORK_DIR/body.bin"

GARBAGE="$WORK_DIR/garbage.png"
printf 'to nie jest obraz' > "$GARBAGE"
send_upload "$GARBAGE" 'garbage.png' "$BODY"
if [ "$UP_STATUS" = '415' ]; then ok=1; else ok=0; fi
write_result "$ok" 'plik niebędący obrazem' "HTTP $UP_STATUS (oczekiwano 415)"

FIRST=''
for f in "${TEST_FILES[@]}"; do
    lower="$(printf '%s' "${f##*.}" | tr '[:upper:]' '[:lower:]')"
    if [ "$lower" = 'png' ] || [ "$lower" = 'jpg' ]; then
        FIRST="$f"
        break
    fi
done

if [ -n "$FIRST" ]; then
    FIRST_NAME="$(basename "$FIRST")"

    send_upload "$FIRST" "$FIRST_NAME" "$BODY" 'quality=abc'
    if [ "$UP_STATUS" = '400' ]; then ok=1; else ok=0; fi
    write_result "$ok" 'nieprawidłowe quality' "HTTP $UP_STATUS (oczekiwano 400)"

    send_upload "$FIRST" "$FIRST_NAME" "$WORK_DIR/low.bin" 'quality=5'
    LOW_STATUS="$UP_STATUS"
    send_upload "$FIRST" "$FIRST_NAME" "$WORK_DIR/high.bin" 'quality=100'
    HIGH_STATUS="$UP_STATUS"
    LOW_SIZE="$(file_size "$WORK_DIR/low.bin")"
    HIGH_SIZE="$(file_size "$WORK_DIR/high.bin")"
    if [ "$LOW_STATUS" = '200' ] && [ "$HIGH_STATUS" = '200' ] && [ "$LOW_SIZE" -lt "$HIGH_SIZE" ]; then ok=1; else ok=0; fi
    write_result "$ok" 'parametr quality' "q5=${LOW_SIZE} B, q100=${HIGH_SIZE} B"
fi

# Podsumowanie i kod wyjścia obsługuje on_exit.
exit 0
