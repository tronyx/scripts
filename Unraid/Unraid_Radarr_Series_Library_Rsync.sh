#!/usr/bin/env bash

# Unraid Radarr TV Shows backup script
# Script to generate a list of Movies from Radarr that were imported within the last X hours, performs an API call to rename them accordingly, and then rsyncs the new/updated media files to a backup Server
# This is designed for use with the User Scripts Plugin

# I use Tdarr (https://github.com/HaveAGitGat/Tdarr) to process all of my media to remove unwanted audio tracks, subtitles, and to ensure that a stereo audio track exists. I also include the audio information in the filename for my media so, after Tdarr does its thing, that changes. That change is NOT picked up by Radarr automatically and you would need to manually refresh & scan and then rename the corresponding media files.
# This script takes care of that for you and then backs everything up to a backup server via rsync.

# Declare some variables
# This is the actual directory name that the media for this library is stored in, IE: "/mnt/user/data/media/Videos/HD Movies"
# You will need to check your Unraid share and directory structure to find the correct path for your setup
libraryName='HD Movies'
radarrURL='http://192.168.1.3:7878/radarr/'
radarrAPIKey='YOUR-API-Key'
movieIDList=$(mktemp)
# The /var/log/directory doesn't exist and will be DELETED every reboot so you will want to use this script too: https://github.com/tronyx/scripts/blob/main/Unraid/Create_Rsync_Logs_Dir.sh
# Use the User Scripts plugin and set it to run when the Array starts.
logFile='/var/log/rsync/hd_movies.log'
curlGETHeaders=( "accept: application/json" "X-Api-Key: ${radarrAPIKey}" )
curlPOSTHeaders=( "${curlGETHeaders[@]}" "Content-Type: application/json" )

# Function to check that the source server NFS share is mounted and functional
# You will need to adjust the remote share mount path accordingly
check_nfs_share() {
    sourceDataShareTouchStatus=$(timeout 15 touch "/mnt/remotes/192.168.1.3_data/media/test" > /dev/null 2>&1 ; echo $?)
    sourceDataShareLsStatus=$(timeout 15 ls -la "/mnt/remotes/192.168.1.3_data/media/test" > /dev/null 2>&1 ; echo $?)
    if [[ ${sourceDataShareTouchStatus} != '0' ]] || [[ ${sourceDataShareLsStatus} != '0' ]]; then
        /usr/local/emhttp/plugins/dynamix/scripts/notify -i "alert" -s "Morgoth Data Share Mount Error!" -d "The remote mount of the Morgoth Data Share is broken!"
        exit 1
    elif [[ ${sourceDataShareTouchStatus} == '0' ]] || [[ ${sourceDataShareLsStatus} == '0' ]]; then
        :
    fi
}

# Function to send a notification to Discord that the sync process has started
# It used this script which you will need to add to your Unraid Server: https://github.com/limetech/dynamix/blob/master/plugins/dynamix/scripts/notify
# Script will be: /usr/local/emhttp/plugins/dynamix/scripts/notify
send_start_notification() {
    /usr/local/emhttp/plugins/dynamix/scripts/notify -i "normal" -s "${libraryName} rSync Started" -d "The automated rSync of the ${libraryName} library has started."
}

# Function to get a list of Movies that have been imported in the last 72 hours
get_movies_list() {
    curl -s -X GET "${radarrURL}api/v3/history/since?date=$(date -d '72 hours ago' "+%Y-%m-%dT%H:%MZ")&includeMovie=true" "${curlGETHeaders[@]/#/-H}" | jq .[].movie.id | sort | uniq > "${movieIDList}"
}

# Function to loop through list of Movies and kick off a 'Refresh & Scan' on each, getting the ID of the command used to ensure it completes before moving to the next one
refresh_movies() {
    while IFS= read -r movieID; do
        refreshTaskID=$(curl -s -X POST "${radarrURL}api/v3/command" "${curlPOSTHeaders[@]/#/-H}" -d "{ \"name\": \"RefreshMovie\", \"movieIds\": [${movieID}] }" | jq -r .id)
        refreshTaskStatus=$(curl -s -X GET "${radarrURL}api/v3/command/${refreshTaskID}" "${curlGETHeaders[@]/#/-H}" | jq -r .status)
        while [[ ${refreshTaskStatus} != 'completed' ]]; do
            sleep 10
            refreshTaskStatus=$(curl -s -X GET "${radarrURL}api/v3/command/${refreshTaskID}" "${curlGETHeaders[@]/#/-H}" | jq -r .status)
        done
    done < <(cat "${movieIDList}")
}

# Function to generate the list of Movies that need to be renamed
# You can obviously change the 72 hours to whatever suits your needs best
get_movie_files() {
    while IFS= read -r movieID; do
        curl -s -X GET "${radarrURL}api/v3/rename?movieId=${movieID}" "${curlGETHeaders[@]/#/-H}" | jq -r .[].movieFileId > /tmp/"${movieID}"_fileIDList
    done < <(cat "${movieIDList}")
}

# Function to loop through list of Movies and kick off a 'Rename' for the file(s) of each, getting the ID of the taslk for the command used to ensure it completes before moving to the next one
rename_movies() {
    while IFS= read -r movieID; do
        fileCount=$(wc -l < /tmp/"${movieID}"_fileIDList)
        if [[ ${fileCount} == '0' ]]; then
            :
        elif [[ ${fileCount} == '1' ]]; then
            movieFileID=$(cat /tmp/"${movieID}"_fileIDList)
            renameTaskID=$(curl -s -X POST "${radarrURL}api/v3/command" "${curlPOSTHeaders[@]/#/-H}" -d "{ \"name\": \"RenameFiles\", \"movieId\": ${movieID}, \"files\": [${movieFileID}] }" | jq -r .id)
            renameTaskStatus=$(curl -s -X GET "${radarrURL}api/v3/command/${renameTaskID}" "${curlGETHeaders[@]/#/-H}" | jq -r .status)
            while [[ ${renameTaskStatus} != 'completed' ]]; do
                sleep 10
                renameTaskStatus=$(curl -s -X GET "${radarrURL}api/v3/command/${renameTaskID}" "${curlGETHeaders[@]/#/-H}" | jq -r .status)
            done
        else
            :
        fi
    done < <(cat "${movieIDList}")
}

# Function to rsync the library to from the source server to the backup server and store the exit code of the process
# You obviously need to make sure that the source and destination paths are correct for your setup. I will NOT be held accountable for any data loss that may happen if something goes wrong.
perform_rsync() {
    rsync -sahvP --del --stats "/mnt/remotes/192.168.1.3_data/media/Videos/${libraryName}/" "/mnt/user/Plex_Media_Backup/Videos/${libraryName}/" > "${logFile}" 2>&1
    rsyncExitCode="$?"
}

# Function to cleanup temp files for the script
cleanup() {
    rm -f /tmp/*_fileIDList /tmp/tmp.* /tmp/movieIDList.txt
}

# Function to check the exit code of the rsync process and send an appropriate notification
send_completed_notification() {
    if [[ ${rsyncExitCode} == '0' ]]; then
        /usr/local/emhttp/plugins/dynamix/scripts/notify -i "normal" -s "${libraryName} rSync Completed" -d "The automated rSync of the ${libraryName} library has completed."
    elif [[ ${rsyncExitCode} == '24' ]]; then
        /usr/local/emhttp/plugins/dynamix/scripts/notify -i "warning" -s "${libraryName} rSync Ecountered A Warning! Check the log for details." -d "The automated rSync of the ${libraryName} library has experienced a WARNING!"
    else
        /usr/local/emhttp/plugins/dynamix/scripts/notify -i "alert" -s "${libraryName} rSync Ecountered An Error! Check the log for details." -d "The automated rSync of the ${libraryName} library has experienced an ERROR!"
    fi
}

# Main function to run all other functions
main() {
    check_nfs_share
    send_start_notification
    get_movies_list
    refresh_movies
    get_movie_files
    rename_movies
    perform_rsync
    cleanup
    sleep 10
    send_completed_notification
}

main