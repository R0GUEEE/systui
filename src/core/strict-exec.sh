#!/bin/bash
# Strict child execution.
#
# run_strict itself is defined once, in src/core/config.sh, which every entry
# point sources first. This module used to carry a second implementation with
# the same name; because both files are sourced into one shell, whichever ran
# last silently won, leaving two bodies to be kept in lockstep. The feature
# loader and the ARG_MAX scrub it needs now live in the single definition.
#
# Keep this file for the modules it documents and for the export scrub below.

export -n -f run_strict 2>/dev/null || true
