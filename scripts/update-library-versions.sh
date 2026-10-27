#!/usr/bin/env bash
#
# Automatycznie podmienia wersje bibliotek (ARG ...) w plikach Dockerfile.* na najnowsze wydania.
#
# Każdy Dockerfile.* definiuje instrukcje ARG z wersją (tagiem git) ImageMagick oraz bibliotek:
# libheif, libaom, libwebp, libjxl. Skrypt pobiera listę tagów z repozytoriów źródłowych
# (git ls-remote --tags), wybiera najnowszą stabilną wersję (pomija -rc, -beta, snapshoty itp.),
# porównuje ją z wersją aktualnie wpisaną w Dockerfile i w razie potrzeby podmienia wartość ARG.
#
# Wymagania: bash, git (w PATH), sort z obsługą -V (GNU coreutils / BSD) oraz dostęp do internetu.

set -u

usage() {
    cat <<'EOF'
Użycie: update-library-versions.sh [opcje] [ŚCIEŻKA...]

Argumenty:
  ŚCIEŻKA                  Pliki Dockerfile lub katalogi zawierające pliki Dockerfile*.
                           Domyślnie: katalog nadrzędny względem skryptu (korzeń repozytorium).

Opcje:
  -p, --path ŚCIEŻKA       Jak argument pozycyjny (można podać wielokrotnie).
  -l, --library NAZWA      Ogranicza aktualizację do wybranych bibliotek (można podać
                           wielokrotnie lub po przecinku).
                           Dozwolone: IM, LIB_HEIF, LIB_AOM, LIB_WEBP, LIBJXL.
  -c, --check-only         Tylko sprawdza dostępność nowszych wersji i wyświetla raport -
                           nie zapisuje zmian.
  -n, --dry-run            Synonim --check-only (odpowiednik -WhatIf).
  -h, --help               Wyświetla tę pomoc.

Przykłady:
  ./update-library-versions.sh
  ./update-library-versions.sh --check-only
  ./update-library-versions.sh --library LIB_HEIF,LIBJXL ../Dockerfile.trixie
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

PATHS=()
LIBRARY_FILTER=()
CHECK_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        -p|--path)
            [ $# -ge 2 ] || { echo "Opcja $1 wymaga wartości." >&2; exit 2; }
            PATHS+=("$2"); shift 2 ;;
        -l|--library)
            [ $# -ge 2 ] || { echo "Opcja $1 wymaga wartości." >&2; exit 2; }
            IFS=',' read -r -a _libs <<< "$2"
            LIBRARY_FILTER+=("${_libs[@]}"); shift 2 ;;
        -c|--check-only|-n|--dry-run) CHECK_ONLY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; PATHS+=("$@"); break ;;
        -*) echo "Nieznana opcja: $1" >&2; usage >&2; exit 2 ;;
        *) PATHS+=("$1"); shift ;;
    esac
done

[ "${#PATHS[@]}" -gt 0 ] || PATHS=("$REPO_ROOT")

# Nazwa ARG | repozytorium | prefiks tagu (np. "v" dla v1.2.3) | wzorzec stabilnej wersji (ERE).
# Wzorzec bez sufiksów -rc/-beta; ImageMagick używa formatu X.Y.Z-N (bez prefiksu).
ALL_ARGS=(IM_VERSION LIB_HEIF_VERSION LIB_AOM_VERSION LIB_WEBP_VERSION LIBJXL_VERSION)

lib_repo() {
    case "$1" in
        IM_VERSION)       echo 'https://github.com/ImageMagick/ImageMagick.git' ;;
        LIB_HEIF_VERSION) echo 'https://github.com/strukturag/libheif.git' ;;
        LIB_AOM_VERSION)  echo 'https://aomedia.googlesource.com/aom' ;;
        LIB_WEBP_VERSION) echo 'https://chromium.googlesource.com/webm/libwebp' ;;
        LIBJXL_VERSION)   echo 'https://github.com/libjxl/libjxl.git' ;;
    esac
}

lib_prefix() {
    case "$1" in
        IM_VERSION) echo '' ;;
        *)          echo 'v' ;;
    esac
}

lib_pattern() {
    case "$1" in
        IM_VERSION) echo '^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$' ;;
        *)          echo '^[0-9]+\.[0-9]+\.[0-9]+$' ;;
    esac
}

LIBRARIES=()
if [ "${#LIBRARY_FILTER[@]}" -gt 0 ]; then
    for name in "${LIBRARY_FILTER[@]}"; do
        case "$name" in
            IM|LIB_HEIF|LIB_AOM|LIB_WEBP|LIBJXL) LIBRARIES+=("${name}_VERSION") ;;
            *)
                echo "Nieprawidłowa biblioteka: '$name'. Dozwolone: IM, LIB_HEIF, LIB_AOM, LIB_WEBP, LIBJXL." >&2
                exit 2 ;;
        esac
    done
else
    LIBRARIES=("${ALL_ARGS[@]}")
fi

if ! command -v git >/dev/null 2>&1; then
    echo 'Nie znaleziono polecenia "git" w PATH. Zainstaluj git i spróbuj ponownie.' >&2
    exit 1
fi

if [ -t 1 ]; then
    C_GRAY=$'\033[90m'; C_CYAN=$'\033[36m'; C_YELLOW=$'\033[33m'; C_RESET=$'\033[0m'
else
    C_GRAY=''; C_CYAN=''; C_YELLOW=''; C_RESET=''
fi

# get_latest_version <repo> <prefiks> <wzorzec>  -> wypisuje najnowszą wersję
get_latest_version() {
    local repo="$1" prefix="$2" pattern="$3" lines tags latest

    if ! lines="$(git ls-remote --tags "$repo" 2>&1)"; then
        echo "git ls-remote nie powiódł się dla $repo: $lines" >&2
        return 1
    fi

    # Wyciągnij nazwy tagów, usuń znacznik "peeled" (^{}), odfiltruj prefiks i wzorzec.
    tags="$(printf '%s\n' "$lines" \
        | sed -n -E 's#.*refs/tags/([^[:space:]]+)$#\1#p' \
        | sed -E 's/\^\{\}$//' \
        | awk -v p="$prefix" 'p == "" { print; next } index($0, p) == 1 { print substr($0, length(p) + 1) }' \
        | grep -E "$pattern" \
        | sort -u)"

    if [ -z "$tags" ]; then
        echo "Nie znaleziono tagów pasujących do wzorca '$pattern' w $repo." >&2
        return 1
    fi

    # Sortowanie numeryczne wersji: "X.Y.Z" a następnie numer buildu po myślniku (ImageMagick).
    latest="$(printf '%s\n' "$tags" | sort -V | tail -n 1)"
    printf '%s\n' "$latest"
}

# replace_arg <plik_wejściowy> <plik_wyjściowy> <ARG> <nowa_wersja>
# Czysty bash zamiast sed: zachowuje końce linii (CRLF) - sed z Git Bash usuwa znaki CR.
replace_arg() {
    local in="$1" out="$2" name="$3" value="$4" line
    local re="^(ARG[[:space:]]+${name}=)([^[:space:]]+)(.*)$"
    : > "$out"
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ $re ]]; then
            line="${BASH_REMATCH[1]}${value}${BASH_REMATCH[3]}"
        fi
        printf '%s\n' "$line" >> "$out"
    done < "$in"
}

# Zbierz pliki Dockerfile
FILES=()
for p in "${PATHS[@]}"; do
    if [ -d "$p" ]; then
        for f in "$p"/Dockerfile*; do
            [ -f "$f" ] && FILES+=("$f")
        done
    elif [ -f "$p" ]; then
        FILES+=("$p")
    else
        echo "${C_YELLOW}OSTRZEŻENIE: Pominięto - ścieżka nie istnieje: $p${C_RESET}" >&2
    fi
done

if [ "${#FILES[@]}" -eq 0 ]; then
    echo 'Nie znaleziono żadnych plików Dockerfile.' >&2
    exit 1
fi

# Pobierz najnowsze wersje (raz na bibliotekę, wspólnie dla wszystkich plików).
# Wyniki trzymane w plikach tymczasowych, by uniknąć tablic asocjacyjnych (bash 3.2 / macOS).
TMP_DIR="$(mktemp -d)" || { echo 'Nie można utworzyć katalogu tymczasowego.' >&2; exit 1; }
trap 'rm -rf "$TMP_DIR"' EXIT

for arg_name in "${LIBRARIES[@]}"; do
    repo="$(lib_repo "$arg_name")"
    echo "${C_GRAY}Sprawdzam $arg_name ($repo)...${C_RESET}"
    if version="$(get_latest_version "$repo" "$(lib_prefix "$arg_name")" "$(lib_pattern "$arg_name")" 2>"$TMP_DIR/err")"; then
        printf '%s' "$version" > "$TMP_DIR/$arg_name"
    else
        echo "${C_YELLOW}OSTRZEŻENIE: [$arg_name] $(cat "$TMP_DIR/err")${C_RESET}" >&2
    fi
done

REPORT=()   # wiersze: plik|ARG|obecna|najnowsza|status
UPDATED=0
PENDING=0

for file in "${FILES[@]}"; do
    changed=0
    new_file="$TMP_DIR/new_content"
    cp "$file" "$new_file"

    for arg_name in "${LIBRARIES[@]}"; do
        [ -f "$TMP_DIR/$arg_name" ] || continue
        new="$(cat "$TMP_DIR/$arg_name")"

        current="$(sed -n -E "s/^ARG[[:space:]]+${arg_name}=([^[:space:]]+).*/\1/p" "$new_file" | head -n 1)"
        [ -n "$current" ] || continue

        if [ "$current" = "$new" ]; then
            status='aktualna'
        elif [ "$CHECK_ONLY" -eq 1 ]; then
            status='dostępna aktualizacja'
            PENDING=$((PENDING + 1))
        else
            replace_arg "$new_file" "$new_file.tmp" "$arg_name" "$new" \
                && mv "$new_file.tmp" "$new_file"
            changed=1
            status='zaktualizowano'
            UPDATED=$((UPDATED + 1))
        fi

        REPORT+=("$(basename "$file")|$arg_name|$current|$new|$status")
    done

    if [ "$changed" -eq 1 ]; then
        # cat zamiast mv - zachowuje uprawnienia i właściciela oryginalnego pliku.
        cat "$new_file" > "$file"
    fi
done

echo
if [ "${#REPORT[@]}" -gt 0 ]; then
    {
        printf '%s\n' 'Plik|ARG|Obecna|Najnowsza|Status'
        printf '%s\n' '----|---|------|---------|------'
        printf '%s\n' "${REPORT[@]}"
    } | awk -F'|' '
        { for (i = 1; i <= NF; i++) { row[NR, i] = $i; if (length($i) > w[i]) w[i] = length($i) } n = NR; nf = NF }
        END {
            for (r = 1; r <= n; r++) {
                line = ""
                for (i = 1; i <= nf; i++) line = line sprintf("%-" w[i] "s  ", row[r, i])
                sub(/ +$/, "", line)
                print line
            }
        }'
    echo
fi

echo "${C_CYAN}Zaktualizowano: $UPDATED; oczekujące (nie zapisano): $PENDING.${C_RESET}"
