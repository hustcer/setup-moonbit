#!/usr/bin/env nu
# filepath: /Users/hustcer/iWork/terminus/setup-moonbit/nu/snapshot.nu

# Moonbit snap script for downloading and managing moonbit core and toolchain binaries

def main [
    channel: string = 'latest'  # Channel to snap (latest or nightly)
    --merge(-m)                 # Merge component index files and produce the main index
    --production(-p)            # Production mode (default is development mode)
    --snap-toolchain(-t)        # Snap moonbit toolchain (default is to snap moonbit core)
    --keep-artifacts(-k)        # Keep artifacts between runs
] {
    # Validate channel
    if not ($channel in ['latest', 'nightly']) {
        error make {msg: "Channel must be 'latest' or 'nightly'"}
    }

    # Set environment variables and defaults
    let production = if $production { true } else { $env.CI? == "true" }
    let keep_artifacts = if $keep_artifacts { true } else { $merge }

    # Debug preference
    let debug_mode = (not $production) or ($env.CI? == "true")

    # Global date variable for nightly builds
    mut date_nightly = "0000-00-00"

    # Define paths
    let script_root = (dirname $nu.current-file)
    let download_dir = $"($script_root)/tmp/download"
    let gha_artifacts_dir = $"($script_root)/tmp/gha-artifacts"
    let dist_dir = $"($script_root)/tmp/dist"
    let dist_v2_basedir = $"($dist_dir)/v2"

    let index_file = $"($dist_v2_basedir)/index.json"
    let channel_index_file = $"($dist_v2_basedir)/channel-($channel).json"

    # Remote URLs
    let libcore_url = $"https://cli.moonbitlang.com/cores/core-($channel).zip"

    # Clear working directories if needed
    if $production and (not $keep_artifacts) {
        debug $debug_mode "Clearing working directories ..."
        rm -rf $download_dir
        rm -rf $gha_artifacts_dir
    }

    print $"INFO: Channel set to: ($channel)"

    # Get deployed index
    get_deployed_index $debug_mode $dist_dir

    # Main execution logic
    if $merge {
        merge_index $debug_mode $channel $gha_artifacts_dir $channel_index_file $dist_v2_basedir $index_file $date_nightly
    } else if $snap_toolchain {
        if $nu.os-info.name == "windows" {
            snap_toolchain $debug_mode 'x86_64-pc-windows' $channel $download_dir $gha_artifacts_dir $channel_index_file $keep_artifacts $date_nightly
        }

        if $nu.os-info.name == "linux" {
            snap_toolchain $debug_mode 'x86_64-unknown-linux' $channel $download_dir $gha_artifacts_dir $channel_index_file $keep_artifacts $date_nightly
        }

        if $nu.os-info.name == "macos" {
            let arch = (uname -sm | str join " ")
            if $arch =~ "arm64" {
                snap_toolchain $debug_mode 'aarch64-apple-darwin' $channel $download_dir $gha_artifacts_dir $channel_index_file $keep_artifacts $date_nightly
            } else {
                snap_toolchain $debug_mode 'x86_64-apple-darwin' $channel $download_dir $gha_artifacts_dir $channel_index_file $keep_artifacts $date_nightly
            }
        }
    } else {
        snap_libcore $debug_mode $libcore_url $channel $download_dir $gha_artifacts_dir $channel_index_file $keep_artifacts $date_nightly
    }
}

# Debug output helper
def debug [enabled condition: string] {
    if $enabled {
        print $condition
    }
}

# Get deployed index
def get_deployed_index [debug_mode dist_dir] {
    debug $debug_mode "Getting the latest deployed index ..."

    if $env.CI? == "true" {
        # CI clone the deployed index using the checkout action
        return
    }

    mkdir $dist_dir
    cd $dist_dir

    # Remove git directory if it exists
    if (ls -a | where name == ".git" | is-empty | not) {
        rm -rf .git
    }

    # Initialize git and fetch the deployed index
    git init --quiet
    git remote add origin 'https://github.com/chawyehsu/moonbit-binaries'
    git fetch --quiet
    git reset --hard origin/gh-pages --quiet
    git clean -fd --quiet

    cd -
}

# Get libcore modified date
def get_libcore_modified_date [debug_mode libcore_url channel] {
    debug $debug_mode "Checking last modified date of moonbit libcore ..."

    let headers = (http head $libcore_url)
    let last_modified = $headers.headers.last-modified
    let date = ($last_modified | into datetime)

    debug $debug_mode $"Moonbit libcore remote last modified: ($date | date to-timezone utc)"

    let date_string = if $channel == 'nightly' {
        $date | date to-timezone utc | format date "%Y-%m-%d"
    } else {
        ""
    }

    [$date, $date_string]
}

# Snap libcore
def snap_libcore [debug_mode libcore_url channel download_dir gha_artifacts_dir channel_index_file keep_artifacts date_nightly] {
    let result = (get_libcore_modified_date $debug_mode $libcore_url $channel)
    let libcore_remote_last_modified = $result.0
    $date_nightly = $result.1

    # Check if channel index exists and parse last modified date
    let channel_index_last_modified = if (ls $channel_index_file | is-empty | not) {
        let channel_index = (open $channel_index_file)
        let last_modified = $channel_index.lastModified
        debug $debug_mode $"Channel index last modified: ($last_modified)"
        ($last_modified | into datetime)
    } else {
        null
    }

    if $channel_index_last_modified != null and ($libcore_remote_last_modified < $channel_index_last_modified) {
        print $"INFO: libcore is up to date. (channel: ($channel))"
        return
    }

    debug $debug_mode "Downloading moonbit libcore pkg ..."
    mkdir -p $download_dir
    cd $download_dir

    let filename = $"moonbit-core-($channel).zip"
    if (not $keep_artifacts) or (not (ls $filename | is-empty | not)) {
        http get $libcore_url | save -f $filename
    }

    debug $debug_mode "Getting moonbit libcore version number ..."
    rm -rf $"($download_dir)/core-($channel)"
    unzip -o $filename -d $"($download_dir)/core-($channel)"

    let libcore_actual_version = (open $"($download_dir)/core-($channel)/core/moon.mod.json" | get version)
    let libcore_pkg_sha256 = (open -r $filename | hash sha256 | str downcase)

    print $"INFO: Found moonbit libcore version: ($libcore_actual_version)"

    let file = if $channel == "latest" {
        $"moonbit-core-v($libcore_actual_version)-universal.zip"
    } else {
        $"moonbit-core-nightly-($date_nightly)-universal.zip"
    }

    let component_libcore = {
        version: $libcore_actual_version
        date: $date_nightly
        name: "libcore"
        file: $file
        sha256: $libcore_pkg_sha256
    }

    debug $debug_mode "Saving libcore component json file ..."
    mkdir -p $gha_artifacts_dir
    $component_libcore | save -f $"($gha_artifacts_dir)/component-moonbit-core.json"

    debug $debug_mode "Saving moonbit libcore pkg ..."
    cp $filename $"($gha_artifacts_dir)/($component_libcore.file)"
    $"($libcore_pkg_sha256)  *($component_libcore.file)" | save -f $"($gha_artifacts_dir)/($component_libcore.file).sha256"

    cd -
}

# Snap toolchain
def snap_toolchain [debug_mode arch channel download_dir gha_artifacts_dir channel_index_file keep_artifacts date_nightly] {
    # Validate architecture
    if not ($arch in ['aarch64-apple-darwin', 'x86_64-apple-darwin', 'x86_64-unknown-linux', 'x86_64-pc-windows']) {
        error make {msg: "Invalid architecture"}
    }

    # Set toolchain URL based on architecture
    let toolchain_url = if $arch == 'aarch64-apple-darwin' {
        $"https://cli.moonbitlang.com/binaries/($channel)/moonbit-darwin-aarch64.tar.gz"
    } else if $arch == 'x86_64-apple-darwin' {
        $"https://cli.moonbitlang.com/binaries/($channel)/moonbit-darwin-x86_64.tar.gz"
    } else if $arch == 'x86_64-unknown-linux' {
        $"https://cli.moonbitlang.com/binaries/($channel)/moonbit-linux-x86_64.tar.gz"
    } else {
        $"https://cli.moonbitlang.com/binaries/($channel)/moonbit-windows-x86_64.zip"
    }

    if $channel == 'nightly' {
        # Get nightly build date from libcore
        debug $debug_mode "Getting nightly build date from libcore ..."
        let libcore_url = $"https://cli.moonbitlang.com/cores/core-($channel).zip"
        let result = (get_libcore_modified_date $debug_mode $libcore_url $channel)
        $date_nightly = $result.1
    }

    debug $debug_mode "Checking last modified date of moonbit toolchain ..."
    let headers = (http head $toolchain_url)
    let toolchain_remote_last_modified = ($headers.headers.last-modified | into datetime)
    debug $debug_mode $"Moonbit toolchain remote last modified: ($toolchain_remote_last_modified | date to-timezone utc)"

    # Check if channel index exists and parse last modified date
    let channel_index_last_modified = if (ls $channel_index_file | is-empty | not) {
        let channel_index = (open $channel_index_file)
        let last_modified = $channel_index.lastModified
        debug $debug_mode $"Channel index last modified: ($last_modified)"
        ($last_modified | into datetime)
    } else {
        null
    }

    if $channel_index_last_modified != null and ($toolchain_remote_last_modified < $channel_index_last_modified) {
        print $"INFO: moonbit toolchain is up to date. (arch: ($arch), channel: ($channel))"
        return
    }

    debug $debug_mode "Downloading moonbit toolchain pkg ..."
    mkdir -p $download_dir
    cd $download_dir

    let filename = if $arch == 'aarch64-apple-darwin' {
        $"moonbit-($channel)-darwin-arm64.tar.gz"
    } else if $arch == 'x86_64-apple-darwin' {
        $"moonbit-($channel)-darwin-x64.tar.gz"
    } else if $arch == 'x86_64-unknown-linux' {
        $"moonbit-($channel)-linux-x64.tar.gz"
    } else {
        $"moonbit-($channel)-win-x64.zip"
    }

    if (not $keep_artifacts) or (not (ls $filename | is-empty | not)) {
        http get $toolchain_url | save -f $filename
    }

    debug $debug_mode "Getting moonbit toolchain version number ..."
    rm -rf $"($download_dir)/moonbit-($channel)"

    if $arch =~ "windows" {
        unzip -o $filename -d $"($download_dir)/moonbit-($channel)"
    } else {
        mkdir -p $"($download_dir)/moonbit-($channel)"
        tar xf $filename -C $"($download_dir)/moonbit-($channel)"
        chmod +x $"($download_dir)/moonbit-($channel)/bin/moonc"
    }

    cd $"($download_dir)/moonbit-($channel)/bin"
    let version_string = (./moonc -v)
    cd -

    # Parse version string with regex
    let version_regex = "v([\\d.]+)(?:\\+([a-f0-9]+))"
    if ($version_string | str replace -r $version_regex -s "${1}+${2}" | str contains "+") {
        let matches = ($version_string | parse -r $version_regex)
        let toolchain_actual_version = $"($matches.capture0)+($matches.capture1)"
        let toolchain_pkg_sha256 = (open -r $filename | hash sha256 | str downcase)

        print $"INFO: Found moonbit toolchain version: ($toolchain_actual_version)"

        let toolchain_pkg_version_mark = if $channel == "latest" {
            $"v($toolchain_actual_version)"
        } else {
            $"nightly-($date_nightly)"
        }

        let file = if $arch == 'aarch64-apple-darwin' {
            $"moonbit-($toolchain_pkg_version_mark)-aarch64-apple-darwin.tar.gz"
        } else if $arch == 'x86_64-apple-darwin' {
            $"moonbit-($toolchain_pkg_version_mark)-x86_64-apple-darwin.tar.gz"
        } else if $arch == 'x86_64-unknown-linux' {
            $"moonbit-($toolchain_pkg_version_mark)-x86_64-unknown-linux.tar.gz"
        } else {
            $"moonbit-($toolchain_pkg_version_mark)-x86_64-pc-windows.zip"
        }

        let component_toolchain = {
            version: $toolchain_actual_version
            name: "toolchain"
            file: $file
            sha256: $toolchain_pkg_sha256
        }

        debug $debug_mode "Saving toolchain component json file ..."
        mkdir -p $gha_artifacts_dir
        $component_toolchain | save -f $"($gha_artifacts_dir)/component-moonbit-toolchain-($arch).json"

        debug $debug_mode "Saving moonbit toolchain pkg ..."
        cp $filename $"($gha_artifacts_dir)/($component_toolchain.file)"
        $"($toolchain_pkg_sha256)  *($component_toolchain.file)" | save -f $"($gha_artifacts_dir)/($component_toolchain.file).sha256"

        cd -
    } else {
        error make {msg: $"Unexpected moonbit toolchain version number found: ($version_string)"}
    }
}

# Merge index files
def merge_index [debug_mode channel gha_artifacts_dir channel_index_file dist_v2_basedir index_file date_nightly] {
    let component_core_json_file = $"($gha_artifacts_dir)/component-moonbit-core.json"
    if not (ls $component_core_json_file | is-empty | not) {
        error make {msg: "Missing component-moonbit-core.json"}
    }

    let component_core_json = (open $component_core_json_file)
    let date_updated = (date now | date to-timezone utc | format date "%Y%m%dT%H%M%S%4f%Z")

    if $channel == 'nightly' {
        $date_nightly = $component_core_json.date
    }

    # Update channel index
    if not (ls $channel_index_file | is-empty | not) {
        let init_channel_index = {
            version: 2
            lastModified: $date_updated
            releases: []
        }
        debug $debug_mode "Creating channel index file ..."
        $init_channel_index | save -f $channel_index_file
    }

    let channel_index = (open $channel_index_file)

    let channel_index_new_release = if $channel == "latest" {
        {
            version: $component_core_json.version
        }
    } else {
        {
            version: $component_core_json.version
            date: $date_nightly
        }
    }

    # Check for duplicate releases
    let release_already_exists = if $channel == "latest" {
        $channel_index.releases | any {|r| $r.version == $channel_index_new_release.version}
    } else {
        $channel_index.releases | any {|r| $r.date == $date_nightly}
    }

    if $release_already_exists {
        let msg = if $channel == "latest" {
            $"latest: ($channel_index_new_release.version)"
        } else {
            $"nightly: ($date_nightly)"
        }

        error make {msg: $"Duplicate release found in channel index. ($msg)"}
    }

    # Update channel index
    let updated_channel_index = {
        version: $channel_index.version
        lastModified: $date_updated
        releases: ($channel_index.releases | append $channel_index_new_release)
    }

    print "INFO: Saving channel index ..."
    $updated_channel_index | save -f $channel_index_file

    # Write component index for each architecture
    for arch in ['aarch64-apple-darwin', 'x86_64-apple-darwin', 'x86_64-unknown-linux', 'x86_64-pc-windows'] {
        let component_toolchain_json_file = $"($gha_artifacts_dir)/component-moonbit-toolchain-($arch).json"
        if not (ls $component_toolchain_json_file | is-empty | not) {
            error make {msg: $"Missing component-moonbit-toolchain-($arch).json"}
        }

        let component_toolchain_json = (open $component_toolchain_json_file)

        let component_toolchain_version = $component_toolchain_json.version
        let component_core_version = $component_core_json.version

        if $component_toolchain_version != $component_core_version {
            error make {msg: $"Version mismatch between core ($component_core_version) and toolchain ($component_toolchain_version, arch: ($arch))"}
        }

        let component_index = {
            version: 2
            components: [
                {
                    name: $component_toolchain_json.name
                    file: $component_toolchain_json.file
                    sha256: $component_toolchain_json.sha256
                },
                {
                    name: $component_core_json.name
                    file: $component_core_json.file
                    sha256: $component_core_json.sha256
                }
            ]
        }

        print $"INFO: Saving component index '($arch).json' ..."

        let component_index_path = if $channel == "latest" {
            $"($dist_v2_basedir)/latest/($component_toolchain_version)"
        } else {
            $"($dist_v2_basedir)/nightly/($date_nightly)"
        }

        mkdir -p $component_index_path
        $component_index | save -f $"($component_index_path)/($arch).json"
    }

    # Update main index
    let index = (open $index_file)
    let should_init_channel = true

    let updated_channels = $index.channels | each {|c|
        if $c.name == $channel {
            $should_init_channel = false
            let updated_c = $c | merge {version: $channel_index_new_release.version}
            if $channel == "nightly" {
                $updated_c | merge {date: $date_nightly}
            } else {
                $updated_c
            }
        } else {
            $c
        }
    }

    let final_channels = if $should_init_channel {
        let init_channel = if $channel == "latest" {
            {
                name: $channel
                version: $channel_index_new_release.version
            }
        } else {
            {
                name: $channel
                version: $channel_index_new_release.version
                date: $date_nightly
            }
        }

        $updated_channels | append $init_channel
    } else {
        $updated_channels
    }

    let updated_index = {
        version: $index.version
        lastModified: $date_updated
        channels: $final_channels
    }

    print "INFO: Saving main index ..."
    $updated_index | save -f $index_file
}
