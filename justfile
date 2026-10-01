default:
    @just --list

check:
    cargo check --tests

lint:
    cargo clippy --tests -- -D warnings

test:
    cargo test

fmt:
    cargo fmt --all

fmt-lua:
    stylua --syntax luau --indent-type Spaces --indent-width 2 lua/ plugin/ tests/

check-fmt-lua:
    stylua --check --syntax luau --indent-type Spaces --indent-width 2 lua/ plugin/ tests/

lint-lua:
    selene --allow-warnings lua/ plugin/ tests/

test-lua:
    lua tests/review_keys.lua
    lua tests/review_git.lua
    lua tests/code.lua
    lua tests/common.lua
