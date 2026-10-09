#!/bin/zsh
# Compiles checkAlert out of main.swift together with test.swift and runs it.
cd "${0:A:h}"
{ awk '/^\/\/ Fire once per crossing/,/^}$/' main.swift; cat test.swift; } > /tmp/claude-usage-test.swift
swiftc /tmp/claude-usage-test.swift -o /tmp/claude-usage-test && /tmp/claude-usage-test
