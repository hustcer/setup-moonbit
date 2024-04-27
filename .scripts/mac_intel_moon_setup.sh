#!/bin/bash

origin="https://cli.moonbitlang.com"
remote="$origin/macos_intel"
local_moon=$HOME/.moon
local="$local_moon/bin"

if [ ! -d "$local" ]; then
  echo "Creating $local folder..."
  mkdir -p "$local"
fi

add_to_shell_config() {
    local shell_config="$1"
    local path_entry="export PATH=\"$local:\$PATH\""

    if [ "$user_shell" = "fish" ]; then
        path_entry="fish_add_path $local"
    fi

    if ! grep -qF "$path_entry" "$shell_config"; then
        echo "Setup successfully!"
        echo "$path_entry" >> "$shell_config"
        echo "Added PATH to $shell_config, please run: source $shell_config"
    else
        echo "Update successfully!"
    fi
}


moonbins=(moon moonc moonfmt moonrun moondoc mooninfo moon_cove_report)

for bin in "${moonbins[@]}"; do
  rm -f "$local/$bin"
done

for bin in "${moonbins[@]}"; do
  echo "Downloading $remote/$bin to $local/$bin"
  curl -s -o "$local/$bin" "$remote/$bin" &
done

wait

for bin in "${moonbins[@]}"; do
  echo "$local/$bin downloaded"
done

for bin in "${moonbins[@]}"; do
  chmod a+x "$local/$bin"
done

user_shell=$(basename "$SHELL")
if [ "$user_shell" = "bash" ]; then
    add_to_shell_config "$HOME/.bashrc"
elif [ "$user_shell" = "zsh" ]; then
    add_to_shell_config "$HOME/.zshrc"
elif [ "$user_shell" = "fish" ]; then
    add_to_shell_config "$HOME/.config/fish/config.fish"
else
    add_to_shell_config "$HOME/.profile"
fi


echo "Downloading moonbit core..."
mkdir -p "$local_moon"/lib
curl -s "$origin/core.zip" -o "$local_moon/lib/core.zip"
cd "$local_moon"/lib || exit 1
rm -rf core
unzip -qq core.zip
rm -f core.zip
cd core || exit 1
PATH=$local moon bundle > /dev/null 2>&1

echo "Install successfully"
