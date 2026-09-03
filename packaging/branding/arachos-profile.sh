# ArachOS terminal defaults.
#
# Graphical terminals use the Chaos artwork through the Fastfetch preset.
# Text-only prompts use the standard eight-spoked asterisk as its compact
# Unicode fallback.
: "${ARACHOS_CHAOS_GLYPH:=✳}"
export ARACHOS_CHAOS_GLYPH

export BLERUST_OS_ICON="$ARACHOS_CHAOS_GLYPH"
if [[ -z ${BLERUST_ICON_COLOR:-} ]]; then
    export BLERUST_ICON_COLOR=$'\e[1;38;2;123;45;38m'
fi

# Use the product preset whenever a shell invokes the normal fastfetch
# command. An explicit --config/-c argument still takes precedence.
if [[ -x /usr/bin/fastfetch && ${BASH_VERSION:-} ]]; then
    fastfetch() {
        local argument
        for argument in "$@"; do
            case "$argument" in
                --config|-c|--config=*)
                    /usr/bin/fastfetch "$@"
                    return
                    ;;
            esac
        done
        /usr/bin/fastfetch --config arachos "$@"
    }
fi
