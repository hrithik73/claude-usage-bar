#!/bin/zsh
# Compiles checkAlert out of main.swift together with test.swift and runs it.
cd "${0:A:h}"
{ awk '/^\/\/ Fire once per crossing/,/^}$/' main.swift; cat test.swift; } > /tmp/tokenbar-test.swift
swiftc /tmp/tokenbar-test.swift -o /tmp/tokenbar-test && /tmp/tokenbar-test
