#!/usr/bin/env bash

set -e

# --- Tool Checks ---
for tool in git docker python; do
    if ! command -v "$tool" &>/dev/null; then
        echo "Error: Required tool '$tool' is not installed or not in PATH." >&2
        exit 1
    fi
done

if ! docker info &>/dev/null; then
    echo "Error: Docker daemon is not running or not accessible." >&2
    exit 1
fi

# --- Argument Handling ---
FUNCTION_NAME=$1
shift
ARGUMENTS=("$@")

# --- Settings & Variables ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
cd "$SCRIPT_DIR"

SETTINGS_FILE="settings/template.json"
IMAGE_NAME="ynput/ayon"
DEFAULT_IMAGE="$IMAGE_NAME:latest"
SERVER_CONTAINER="server"

TAG=$(git describe --tags --always --dirty 2>/dev/null || echo "untagged")

# Abstract the 'docker compose' / 'docker-compose' command.
if command -v docker-compose &> /dev/null; then
    COMPOSE="docker-compose"
elif docker compose version &> /dev/null; then
    COMPOSE="docker compose"
else
    echo "Error: Neither 'docker-compose' nor 'docker compose' command found." >&2
    exit 1
fi

usage() {
    echo ""
    echo "Ayon server $TAG"
    echo ""
    echo "Usage: ./manage.sh [target]"
    echo ""
    echo "Runtime targets:"
    echo "  setup          Apply settings template from the settings/template.json"
    echo "  dbshell        Open a PostgreSQL shell"
    echo "  reload         Reload the running server"
    echo "  demo           Create demo projects based on settings in demo directory"
    echo ""
    echo "Development:"
    echo "  backend        Download / update backend git repository"
    echo "  frontend       Download / update frontend git repository"
    echo "  build          Build docker image"
    echo "  relinfo        Create RELEASE file with version info (debugging)"
    echo "  dist           Build and publish docker image to Docker Hub"
    echo "  dump [PROJECT]   Dump project database into a file"
    echo "  restore [PROJECT] Restore project database from a file"
    echo ""
}

sanitize_project_name() {
    # Only allow alphanumeric, underscore, and dash
    echo "$1" | sed 's/[^a-zA-Z0-9_-]//g'
}

setup() {
    echo "Server container: $SERVER_CONTAINER"
    if [ ! -f "$SCRIPT_DIR/settings/template.json" ]; then
        echo "No template.json found, running setup without it."
        $COMPOSE exec -T "$SERVER_CONTAINER" python -m setup
    else
        echo "Piping template.json to setup..."
        cat "$SCRIPT_DIR/settings/template.json" | $COMPOSE exec -T "$SERVER_CONTAINER" python -m setup -
    fi
    $COMPOSE exec "$SERVER_CONTAINER" bash "/backend/reload.sh"
}

dbshell() {
    $COMPOSE exec postgres psql -U ayon ayon
}

reload() {
    $COMPOSE exec "$SERVER_CONTAINER" bash "/backend/reload.sh"
}

demo() {
    if ls demo/*.json 1> /dev/null 2>&1; then
        for file in demo/*.json; do
            echo "Applying demo file: $file"
            cat "$file" | $COMPOSE exec -T "$SERVER_CONTAINER" python -m demogen
        done
    else
        echo "No demo files found in demo/*.json"
    fi
}

update() {
    docker pull "$DEFAULT_IMAGE"
    $COMPOSE up --detach --build "$SERVER_CONTAINER"
}

relinfo() {
    local backend_dir="$SCRIPT_DIR/backend"
    local frontend_dir="$SCRIPT_DIR/frontend"
    local output_file="$SCRIPT_DIR/RELEASE"

    echo "Generating RELEASE file..."

    local backend_version
    backend_version=$(python -c "import sys; sys.path.insert(0, '$backend_dir'); from ayon_server.version import __version__; print(__version__)")

    local build_date=$(date +"%Y%m%d")
    local build_time=$(date +"%H%M")

    local backend_branch=$( (cd "$backend_dir" && git branch --show-current) )
    local backend_commit=$( (cd "$backend_dir" && git rev-parse --short HEAD) )
    local frontend_branch=$( (cd "$frontend_dir" && git branch --show-current) )
    local frontend_commit=$( (cd "$frontend_dir" && git rev-parse --short HEAD) )

    cat <<EOF > "$output_file"
version=$backend_version
build_date=$build_date
build_time=$build_time
frontend_branch=$frontend_branch
backend_branch=$backend_branch
frontend_commit=$frontend_commit
backend_commit=$backend_commit
EOF
    echo "RELEASE file created at $output_file"
}

build() {
    echo "Starting build process..."
    backend
    frontend
    relinfo
    echo "Building docker image: $IMAGE_NAME:$TAG"
    docker build -t "$IMAGE_NAME:$TAG" -t "$IMAGE_NAME:latest" .
    echo "Build complete."
}

dist() {
    build
    echo "Publishing docker images to registry..."
    docker push "$IMAGE_NAME:$TAG"
    docker push "$IMAGE_NAME:latest"
    echo "Publish complete."
}

backend() {
    if [ -d "$SCRIPT_DIR/backend/.git" ]; then
        git -C "$SCRIPT_DIR/backend" pull
    else
        rm -rf "$SCRIPT_DIR/backend"
        git clone https://github.com/ynput/ayon-backend "$SCRIPT_DIR/backend"
    fi
}

frontend() {
    if [ -d "$SCRIPT_DIR/frontend/.git" ]; then
        git -C "$SCRIPT_DIR/frontend" pull
    else
        rm -rf "$SCRIPT_DIR/frontend"
        git clone https://github.com/ynput/ayon-frontend "$SCRIPT_DIR/frontend"
    fi
}

dump() {
    local project_name
    project_name=$(sanitize_project_name "$1")
    if [ -z "$project_name" ]; then
        echo "Error: Project name is required." >&2
        echo "Usage: ./manage.sh dump [PROJECT]" >&2
        exit 1
    fi

    echo "Dumping project '$project_name'"
    local dump_file="dump.$project_name.sql"

    {
        echo "DROP SCHEMA IF EXISTS project_$project_name CASCADE;"
        echo "DELETE FROM public.projects WHERE name = '$project_name';"
    } > "$dump_file"

    $COMPOSE exec -T postgres pg_dump --table=public.projects --column-inserts -U ayon ayon | \
        grep "^INSERT INTO" | \
        grep "'$project_name'" >> "$dump_file" || true

    echo "Dumping product types..."
    local types
    types=$($COMPOSE exec -T postgres psql -U ayon ayon -Atc "SELECT DISTINCT(product_type) from project_$project_name.products;" || true)
    for pt in $types; do
        echo "INSERT INTO public.product_types (name) VALUES ('$pt') ON CONFLICT DO NOTHING;" >> "$dump_file"
    done

    echo "Dumping project schema..."
    $COMPOSE exec -T postgres pg_dump --schema="project_$project_name" -U ayon ayon >> "$dump_file"

    echo "Dump complete: $dump_file"
}

restore() {
    local project_name
    project_name=$(sanitize_project_name "$1")
    if [ -z "$project_name" ]; then
        echo "Error: Project name is required." >&2
        echo "Usage: ./manage.sh restore [PROJECT]" >&2
        exit 1
    fi

    local dump_file="dump.$project_name.sql"

    if [ ! -f "$dump_file" ]; then
        echo "Error: Dump file $SCRIPT_DIR/$dump_file not found" >&2
        exit 1
    fi

    echo "Restoring project '$project_name' from $dump_file..."
    cat "$dump_file" | $COMPOSE exec -T postgres psql -U ayon ayon
    echo "Restore complete."
}

main() {
    case "$FUNCTION_NAME" in
        setup)
            setup
            ;;
        dbshell)
            dbshell
            ;;
        reload)
            reload
            ;;
        demo)
            demo
            ;;
        update)
            update
            ;;
        build)
            build
            ;;
        relinfo)
            relinfo
            ;;
        dist)
            dist
            ;;
        backend)
            backend
            ;;
        frontend)
            frontend
            ;;
        dump)
            dump "${ARGUMENTS[@]}"
            ;;
        restore)
            restore "${ARGUMENTS[@]}"
            ;;
        "" | "-h" | "--help")
            usage
            ;;
        *)
            echo "Unknown function: $FUNCTION_NAME" >&2
            usage
            exit 1
            ;;
    esac
}

main "$FUNCTION_NAME" "${ARGUMENTS[@]}"