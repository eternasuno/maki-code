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
    stylua --syntax luau --indent-type Spaces --indent-width 2 lua/ plugin/ tests/*.lua

check-fmt-lua:
    stylua --check --syntax luau --indent-type Spaces --indent-width 2 lua/ plugin/ tests/*.lua

lint-lua:
    selene --allow-warnings lua/ plugin/ tests/*.lua

test-lua:
    lua tests/review_keys.lua
    lua tests/code.lua
    lua tests/common.lua
