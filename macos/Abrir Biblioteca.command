#!/bin/bash
# Remove o atributo de quarentena do arquivo de dados antes de abrir o programa.
# O Chrome (re)adiciona esse atributo ao salvar via File System Access API,
# o que impede o seletor de arquivos de exibir o biblioteca.txt.
xattr -d com.apple.quarantine "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Biblioteca/biblioteca.txt" 2>/dev/null

# O motor fica ao lado quando distribuido, e um nivel acima aqui no repositorio.
DIR="$(cd "$(dirname "$0")" && pwd)"
HTML="$DIR/biblioteca.html"
[ -f "$HTML" ] || HTML="$DIR/../biblioteca.html"

open -a "Google Chrome" "$HTML"
