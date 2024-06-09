#!/bin/bash

remote="https://cli.moonbitlang.com/ubuntu_x86"
local="$HOME/.moon/bin"

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


moonbins=(moon moonc moonfmt moonrun mooninfo moondoc)

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

