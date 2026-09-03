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

if [[ -n ${BASH_VERSION:-} && $- == *i* ]]; then
    _configure_prompt() {
        local C_YELLOW='\[\e[1;38;2;215;153;33m\]'
        local C_FED_BLUE='\[\e[1;38;2;123;45;38m\]'
        local C_CYAN='\[\e[1;38;2;46;194;126m\]'
        local C_RED='\[\e[1;38;2;237;51;59m\]'
        local C_RESET='\[\e[0m\]'
        local C_BOLD_TYPED='\[\e[1m\]'

        local branch
        branch=$(git branch --show-current 2>/dev/null)
        local GIT_INFO=""
        [[ -n "$branch" ]] && GIT_INFO=" ($branch)"

        PS1="\n${C_YELLOW}╭─ ${C_FED_BLUE}${ARACHOS_CHAOS_GLYPH} \u${C_YELLOW}@${C_FED_BLUE}\h ${C_YELLOW}: ${C_CYAN}\w ${C_RED}${C_FED_BLUE}${GIT_INFO}\n${C_YELLOW}╰─λ ${C_RESET}${C_BOLD_TYPED}"
    }
    PROMPT_COMMAND=_configure_prompt
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
