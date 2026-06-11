#!/bin/sh
# Guarded clipboard copy: an empty / accidental selection must never overwrite
# the clipboard (which otherwise presents as "copying randomly stopped
# working"). Lifted from the crewai-field-labs container config.
sel=$(cat)
[ -n "$sel" ] && printf '%s' "$sel" | pbcopy
