#!/usr/bin/env bash

# Unraid Sonarr TV Shows backup script
# Script to generate a list of Series from Sonarr that had episodes imported within the last X hours, performs an API call to rename the episodes accordingly, and then rsyncs the new/updated media files to a backup Server

# Declare some variables
libraryName='TV Shows' # This is the actual directory name that the media for this library is stored in
sonarrURL='http://192.168.1.3:9898/sonarr/'
sonarrAPIKey='YOUR-API-KEY'
seriesIDList=$(mktemp)
logFile='/var/log/rsync/tv_shows.log' # The /var/log/directory doesn't exist and will be DELETED every reboot so you will want to use this script too: 
curlGETHeaders=( "accept: application/json" "X-Api-Key: ${sonarrAPIKey}" )
curlPOSTHeaders=( "${curlGETHeaders[@]}" "Content-Type: application/json" )

# Function to check that the source server NFS share is mounted and functional
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

# Function to get a list of Series that had episodes imported in the last 72 hours
get_series_list() {
    curl -s -X GET "${sonarrURL}api/v3/history/since?date=$(date -d '72 hours ago' "+%Y-%m-%dT%H:%MZ")&includeSeries=true&includeEpisode=false" "${curlGETHeaders[@]/#/-H}" | jq .[].series.id | sort | uniq > "${seriesIDList}"
    #curl -s -X GET "${sonarrURL}api/v3/history/since?date=$(date -d '700 hours ago' "+%Y-%m-%dT%H:%MZ")&includeSeries=true&includeEpisode=false" "${curlGETHeaders[@]/#/-H}" | jq .[].series.id | sort | uniq > "${seriesIDList}"
}

# Function to loop through list of Series and kick off a 'Refresh & Scan' on each, getting the ID of the command used to ensure it completes before moving to the next one
refresh_series() {
    while IFS= read -r seriesID; do
        refreshTaskID=$(curl -s -X POST "${sonarrURL}api/v3/command" "${curlPOSTHeaders[@]/#/-H}" -d "{ \"name\": \"RefreshSeries\", \"seriesId\": ${seriesID} }" | jq -r .id)
        refreshTaskStatus=$(curl -s -X GET "${sonarrURL}api/v3/command/${refreshTaskID}" "${curlGETHeaders[@]/#/-H}" | jq -r .status)
        while [[ ${refreshTaskStatus} != 'completed' ]]; do
            sleep 10
            refreshTaskStatus=$(curl -s -X GET "${sonarrURL}api/v3/command/${refreshTaskID}" "${curlGETHeaders[@]/#/-H}" | jq -r .status)
        done
    done < <(cat "${seriesIDList}")
}

# Function to retrieve the list of episodes that need to be renamed for each series
get_episodes() {
    while IFS= read -r seriesID; do
        curl -s -X GET "${sonarrURL}api/v3/rename?seriesId=${seriesID}" "${curlGETHeaders[@]/#/-H}" | jq -r .[].episodeFileId > /tmp/"${seriesID}"_episodeFileIDsList
    done < <(cat "${seriesIDList}")
}

# Function to loop through list of Series and kick off a 'Rename' for the file(s) of each, getting the ID of the command used to ensure it completes before moving to the next one
rename_episodes() {
    while IFS= read -r seriesID; do
        episodeCount=$(wc -l < /tmp/"${seriesID}"_episodeFileIDsList)
        if [[ ${episodeCount} == '0' ]]; then
            :
        elif [[ ${episodeCount} -gt '0' ]]; then
            if [[ ${episodeCount} == '1' ]]; then
                renameTaskID=$(curl -s -X POST "${sonarrURL}api/v3/command" "${curlPOSTHeaders[@]/#/-H}" -d "{ \"name\": \"RenameFiles\", \"seriesId\": ${seriesID}, \"files\":[$(cat episodeCount="$(wc -l < /tmp/"${seriesID}"_episodeFileIDsList)")] }" | jq -r .id)
                renameTaskStatus=$(curl -s -X GET "${sonarrURL}api/v3/command/${renameTaskID}" "${curlGETHeaders[@]/#/-H}" | jq -r .status)
                while [[ ${renameTaskStatus} != 'completed' ]]; do
                    sleep 10
                    renameTaskStatus=$(curl -s -X GET "${sonarrURL}api/v3/command/${renameTaskID}" "${curlGETHeaders[@]/#/-H}" | jq -r .status)
                done
            elif [[ ${episodeCount} -gt '1' ]]; then
                renameTaskID=$(curl -s -X POST "${sonarrURL}api/v3/command" "${curlPOSTHeaders[@]/#/-H}" -d "{ \"name\": \"RenameFiles\", \"seriesId\": ${seriesID}, \"files\":[$(paste -sd, /tmp/"${seriesID}"_episodeFileIDsList)] }" | jq -r .id)
                renameTaskStatus=$(curl -s -X GET "${sonarrURL}api/v3/command/${renameTaskID}" "${curlGETHeaders[@]/#/-H}" | jq -r .status)
                while [[ ${renameTaskStatus} != 'completed' ]]; do
                    sleep 10
                    renameTaskStatus=$(curl -s -X GET "${sonarrURL}api/v3/command/${renameTaskID}" "${curlGETHeaders[@]/#/-H}" | jq -r .status)
                done
            fi
        fi
    done < <(cat "${seriesIDList}")
}

# Function to rsync the library to from the source server to the backup server and store the exit code of the process
perform_rsync() {
    rsync -sahvP --del --stats "/mnt/remotes/192.168.1.3_data/media/Videos/${libraryName}/" "/mnt/user/Plex_Media_Backup/Videos/${libraryName}/" > "${logFile}" 2>&1
    rsyncExitCode="$?"
}

# Function to cleanup temp files
cleanup() {
    rm -f /tmp/*_episodeFileIDsList /tmp/tmp.* /tmp/seriesIDList.txt
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
    get_series_list
    refresh_series
    get_episodes
    rename_episodes
    perform_rsync
    cleanup
    sleep 10
    send_completed_notification
}

main