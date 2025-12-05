#!/bin/bash -

##
# Varialbes
##
DOWNLOAD_FILE="/tmp/tmux_net_speed.download"
UPLOAD_FILE="/tmp/tmux_net_speed.upload"

get_tmux_option() {
    local option=$1
    local default_value=$2
    local option_value="$(tmux show-option -gqv "$option")"

    if [[ -z "$option_value" ]]; then
        echo "$default_value"
    else
        echo "$option_value"
    fi
}

set_tmux_option() {
    local option=$1
    local value=$2
    tmux set-option -gq "$option" "$value"
}

get_velocity()
{
    local new_value=$1
    local old_value=$2

    # Consts
    local THOUSAND=1024
    local MILLION=1048576

    local interval=$(get_tmux_option 'status-interval' 5)
    local vel=$(( ( new_value - old_value ) / interval ))
    local vel_kb=$(( vel / THOUSAND ))
    local vel_mb=$(( vel / MILLION ))

    if [[ $vel_mb != 0 ]] ; then
        echo -n "$vel_mb MB/s"
    elif [[ $vel_kb != 0 ]] ; then
        echo -n "$vel_kb KB/s";
    else
        echo -n "$vel B/s";
    fi
}

# Reads from value from file. If file does not exist,
# is empty, or not readable, starts back at 0
read_file()
{
    local path="$1"
    local fallback_val=0

    # File exists and is readable?
    if [[ ! -f "$path" ]] ; then
        # File doesn't exist, initialize it for next run
        write_file "$path" "$fallback_val" 2>/dev/null
        echo $fallback_val
        return 1
    elif [[ ! -r "$path" ]]; then
        echo $fallback_val
        return 1
    fi

    # Does the file have content?
    tmp=$(< "$path")
    if [[ "x${tmp}" == "x" ]] ; then
        echo $fallback_val
        return 1
    fi

    # Now return known value
    echo $tmp
}

# Update values in file (atomic write to prevent corruption)
write_file()
{
    local path="$1"
    local val="$2"
    local tmp_path="${path}.tmp.$$"
    local tmp_dir=$(dirname "$path")

    # Check if tmp directory is writable
    if [[ ! -w "$tmp_dir" ]]; then
        echo "[tmux-net-speed] Error: Cannot write to $tmp_dir" >&2
        return 1
    fi

    # Write to temporary file first
    echo "$val" > "$tmp_path" 2>/dev/null || {
        echo "[tmux-net-speed] Error: Failed to write to $tmp_path" >&2
        return 1
    }
    
    # Atomically move to final location
    mv "$tmp_path" "$path" 2>/dev/null || {
        rm -f "$tmp_path" 2>/dev/null
        echo "[tmux-net-speed] Error: Failed to move $tmp_path to $path" >&2
        return 1
    }
}

get_interfaces()
{
    local interfaces=$(get_tmux_option @net_speed_interfaces "")

    if [[ -z "$interfaces" ]] ; then
        for interface in /sys/class/net/*; do
            interfaces+=$(echo $(basename $interface) " ");
        done
    fi

    # Do not quote the variable. This way will handle trailing whitespace
    echo -n $interfaces
}

sum_speed()
{
    local column=$1

    if is_osx ; then
        # On macOS, use netstat instead of /proc/net/dev
        # Only read from active interfaces (those with actual traffic)
        # We need to extract only the Link line for each interface to avoid duplicates
        # Skip loopback and virtual interfaces
        # Column 7 = Ibytes (received), Column 10 = Obytes (sent)
        
        local map_column=$column
        if [[ $column == "1" ]]; then
            map_column=7  # Ibytes for download
        elif [[ $column == "9" ]]; then
            map_column=10  # Obytes for upload
        fi
        
        local val=0
        netstat -ibn 2>/dev/null | awk -v col="$map_column" '
            /<Link#/ {
                # Extract interface name
                intf = $1
                
                # Only count real network interfaces (en0, en1, etc)
                if (intf ~ /^en[0-9]+$/ || intf ~ /^en[0-9]+\./) {
                    bytes = $col
                    if (bytes ~ /^[0-9]+$/) {
                        val += bytes
                    }
                }
            }
            END {
                print val
            }
        '
        return 0
    fi

    declare -a interfaces=$(get_interfaces)

    local line=""
    local val=0
    for intf in ${interfaces[@]} ; do
        line=$(cat /proc/net/dev | grep "$intf" | cut -d':' -f 2)
        speed="$(echo -n $line | cut -d' ' -f $column)"
        let val+=${speed:=0}
    done

    echo $val
}

is_osx() {
    [ $(uname) == "Darwin" ]
}

is_cygwin() {
    command -v WMIC > /dev/null
}

command_exists() {
    local command="$1"
    type "$command" >/dev/null 2>&1
}
