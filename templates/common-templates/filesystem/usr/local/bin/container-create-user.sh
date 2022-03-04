#!/bin/bash
# DUE_VERSION_COMPATIBILITY_TRACKING=1.0.0
# SCRIPT_PURPOSE: Dynamically add a user to a docker container

# Copyright 2019,2020 Cumulus Networks, Inc.  All rights reserved.
#
#  SPDX-License-Identifier:     MIT

# This script is installed by the Dockerfile when the image is
# created. It has three user environment scenarios
#
# 1 - Run as invoking user. In this case the invoking user's username
#     userid, and group are added as an account in the container.
# 2 - Run as existing user. In this case, the user's home directory
#      becomes whatever the existing user's one is.
#      For example, if the container has a 'build' user with /home/build,
#      The user running the container can become 'build', though they will
#      still keep their own user ID
# 3 - Run a command.  This invokes a command as a particular user.
#      Handy for 'just building something' without having to log into the
#      container.

# Default to Debian, unless otherwise specified.
OS_TYPE="Debian"

if [ -e /etc/redhat-release ];then
    OS_TYPE="RedHat"
fi

function fxnPP()
{
    echo "$@"
}

# A universal error checking function. Invoke as:
# fxnEC <command line> || exit 1
# Example:  fxnEC cp ./foo /home/bar || exit 1
function fxnEC ()
{

    # actually run the command
    "$@"

    # save the status so it doesn't get overwritten
    status=$?
    # Print calling chain (BASH_SOURCE) and lines called from (BASH_LINENO) for better debug
    if [ $status -ne 0 ];then
        echo "ERROR [ $status ] in ${BASH_SOURCE[1]##*/}, line #${BASH_LINENO[0]}, calls [ ${BASH_LINENO[*]} ] command: \"$@\"" 1>&2
    fi

    #$resetDebug
    return $status
}

# Standardized error messaging
function fxnERR
{
    echo ""
    # Print script name, and line original macro was on.
    printf "ERROR at ${BASH_SOURCE[1]##*/} line ${BASH_LINENO[1]} :  %s\n" "$1"
    echo ""
}

SEND_ERRORS="/dev/null"
#
# This creates a user on the fly for the container,
# Unless that user already exists.
# If the user id passed in is different than what is in the container, it
# will change the container's user ID to match.
#
function fxnAddUserInContainer()
{
    local containerUserName
    local containerUID
    local addGroupID=""
    local userShell="/bin/bash"
    # Check for namespace collisions
    local userAlreadyExistsInContainer="FALSE"
    local userIDAlreadyUsedBy=""

    echo " ___________________________________________________________________________"
    echo "|                                                                           |"

    if [ "$DOCKER_GID_MESSAGE" != "" ];then
        # If this container has docker, note that container docker's
        # group id was set to match the host's
        echo "$DOCKER_GID_MESSAGE"
    fi
    #Does the user name already exist?
    # Anchor match to start of line and first : to prevent partial matches
    containerUserName=$(grep  ^"${USER_NAME}": /etc/passwd | sed -e 's/:.*//g' )

    if [ "$containerUserName" != "" ];then
        # If this account already exists in the container, get it's ID
        # In case it is NOT overridden by command line arguments
        containerUID=$( grep  ^"${USER_NAME}": /etc/passwd | awk -F ':' '{print$3}' )

        echo "| User account [ $containerUserName ]:[ $containerUID ] exists in container."
        userAlreadyExistsInContainer="TRUE"
    fi

    #
    # Sanity check passed in user ID and user name against existing user
    # names and IDs present in the container. There are four possible outcomes:
    #
    if [ "$userAlreadyExistsInContainer" = "TRUE" ];then
        #
        # The passed in user name already exists in the container
        # Go with whatever the container settings are, as there may
        # be internal dependencies on the user id/groups.
        # The user can specify a --home-dir for the container account,
        # or run as a non conflicting user.
        if [ "$containerUID" != "$USER_ID" ];then

            echo "|   Warning: Container already has [ $containerUserName ]:[ $containerUID ]. Using those."

            USER_ID="$containerUID"
            GROUP_ID="$(id --group $USER_NAME )"
            GROUP_NAME="$(id --name --group $USER_NAME)"


        fi
    fi

    #
    # Sanity check the user's group id.
    # Things can only go wrong here, so don't print status, just errors.
    #

    # Only try to set this if it was passed
    # otherwise it evaluates to a blank line.
    if [ "$GROUP_ID" != "" ];then
        # Stash this for use during user account creation
        addGroupID=" --gid $GROUP_ID "

        if [ "$GROUP_NAME" != "" ];then
            # Does the group exist in the container already
            grep -q "^${GROUP_NAME}:" /etc/group
            if [ $? = 0 ];then
                # group exists. If the IDs don't match, we're cooked
                containerGroupID=$( grep "^${GROUP_NAME}:" /etc/group | awk -F ':' '{print$3}' )
                if [ "$containerGroupID" != "$GROUP_ID" ];then
                    echo "ERROR! Passed in group ID of [ $GROUP_ID ] conflicts with [ $containerGroupID ] for group [ $GROUP_NAME ]. Exiting."
                    exit 1
                fi
                # IDs match and group exists. That's fortunate. Carry on.
            else
                # Group name does not exist. Time to make it.
                # Use --non-unique so if there is another group with the same ID,
                # the new name will be created with the same ID in /etc/groups
                # so that there are two different names with the same ID.
                # The goal is to have host-consistent groups on the files when
                # the contiainer exits, and to have the correct ID associated
                # with either group name inside the container.
                groupadd --non-unique --gid "$GROUP_ID" "$GROUP_NAME"
                if [ $? != 0 ];then
                    echo "ERROR! In container, failed to create group [ $GROUP_NAME] with ID [ $GROUP_ID ]. Exiting."
                    exit 1
                fi
                # Now the group the user will be added to exists.
            fi
        fi
    fi

    #
    # Make sure the user ID isn't already in use by somebody else.
    #
    userIDAlreadyUsedBy=$(getent passwd "$USER_ID")
    # If it is not in use, then proceed.
    if [[ "$userIDAlreadyUsedBy" != "" ]];then
        # If it is already associated with the user account, then proceed,
        # since that is what we are aiming for anyway...
        if [[ "$userIDAlreadyUsedBy" != "${USER_NAME}:"* ]];then
            #
            # user name is unique, but user ID is in use elsewhere. Fail the operation.
            #
            fxnERR "Cannot create user $USER_NAME with UID [ $USER_ID ]. UID in use by $userIDAlreadyUsedBy"
            exit 1
        fi
    fi
    #
    # The passed in user name does not exist in the container.
    # Create it.
    #
    if [ "$userAlreadyExistsInContainer" = "FALSE" ];then
        #
        # User name and ID are unique: create the user
        #
        echo "| $USER_NAME : Creating user UID [ $USER_ID ] GID [ $GROUP_ID ] Group [ $GROUP_NAME ]"
        # if a home directory exists, do not create it
        if [ -e /home/"$USER_NAME" ];then
            makeHomeDir=" --no-create-home "
            echo "| $USER_NAME : /home directory already exists. Not creating."
        else
            echo "| $USER_NAME : /home directory does not exist. Creating..."
        fi

        # Don't create home directory - we presume it is getting mounted
        # use --gecos "" to supply blank data for Full Name, Room number, etc
        if [ "$OS_TYPE" = "RedHat" ];then
            if [ ! -d /home/"$USER_NAME" ];then
                # useradd throws warnings if this already exists
                makeHomeDir=" --home-dir /home/ $USER_NAME"
            fi
            useradd $makeHomeDir \
                    --gid "$GROUP_ID" \
                    --shell "$userShell" \
                    --uid "$USER_ID" \
                    "$USER_NAME"
        else
            fxnEC adduser --home /home/"$USER_NAME" \
                  $makeHomeDir \
                  --shell "$userShell" \
                  --uid "$USER_ID" \
                  $addGroupID \
                  --gecos "" \
                  > /dev/null || exit 1
        fi
    fi

    #
    # Configure the user account, which may have been created by
    # the program running the container by default, and needs to
    # be updated to reflect what the current user is running.
    # If the account was just created, then this is redundant, but fast.
    #
    fxnPP "| Configuring  [ $USER_NAME ] sudo, $addGroupID, shell [ $userShell ]."
    # Usermod may echo 'no changes' to stderr, so filter that.
    # If there is a real problem, it'll exit.
    fxnEC usermod \
          --shell "$userShell" \
          $addGroupID \
          "$USER_NAME"  > /dev/null 2>&1 || exit

    if [ "$OS_TYPE" = "RedHat" ];then
        # Allow this user to become root
        usermod -aG wheel "$USER_NAME"
    else
        # Allow this user to become root
        fxnEC adduser "$USER_NAME" sudo > /dev/null || exit 1
    fi

    fxnPP "| Passwordless [ $USER_NAME ]."
    # Make sure the in-contianer password is empty.
    # This is about convenience, not security.
    fxnEC passwd -d "$USER_NAME" > /dev/null || exit 1

    # Do not require password to become root via 'sudo su'
    echo "$USER_NAME       ALL=(ALL:ALL) NOPASSWD: ALL" >> /etc/sudoers

    # If this container has Docker installed and will be using it.
    if [ "$HOST_DOCKER_GID" != "" ];then
        # Make sure the user a member of the docker group.
        if grep -q "docker:" /etc/group ; then
            fxnPP "| Adding [ $USER_NAME ] to docker group. "
            fxnEC adduser "$USER_NAME" docker > /dev/null || exit 1
        fi
    fi
    echo "|___________________________________________________________________________|"
    if [ -e /etc/due-bashrc ];then
        echo "|                                                                           |"
        echo "|               Appending container /etc/due-bashrc                         |"
        echo "|___________________________________________________________________________|"

        . /etc/due-bashrc
    fi

    if [ 1 = 0 ];then
        echo "Force allow user"
        # Allow this user to become root
        fxnPP "| $USER_NAME : adding to sudoers file."
        fxnEC adduser "$USER_NAME" sudo > /dev/null || exit 1
        # Do not require password to become root via 'sudo su'
        echo "$USER_NAME       ALL=(ALL:ALL) NOPASSWD: ALL" >> /etc/sudoers
    fi
}

#
# run a passed in command as the specified user.
#
function fxnRunAsUser()
{
    local result

    # To pass a build command in, so that the build happens as the user,
    # use the format:
    #  due --run --command /usr/local/bin/duebuild
    #      --use-directory /host-absolute-path-to-builddir/
    #      --build
    if [ "$COMMAND_LIST" != "" ];then
        echo "|"
        echo "| Running [ $COMMAND_LIST ]"
        echo "|  ...as user [ $USER_NAME ] UID [ $USER_ID ]"
        echo "|__________________________________________________________________________"
        # run the rest of it in a shell in case there's multiple commands in there
        # Suggested format for chaining commands in command list: cmd1 && cmd2 && cmd3
        # Run as specified user
        /bin/su - ${USER_NAME} bash -c "$COMMAND_LIST"
        result=$?
        echo " ___________________________________________________________________________"
        echo "|                                                                           |"
        echo "| Done   [ $COMMAND_LIST ]"
        echo "| Status [ $result ]"
        echo "|___________________________________________________________________________|"
        # Make sure the result of the command is returned
        return $result
    else
        echo "|                                                                           |"
        echo "| Container log in text follows:                                            |"
        echo "|___________________________________________________________________________|"
        echo ""

        if [ "$OS_TYPE" = "RedHat" ];then
            # Login behaves differently here, but su and cd _seem_ to be equivalent...
            cd "$(sudo -u $USER_NAME sh -c 'echo $HOME')"
            su "${USER_NAME}"

        else
            # Log in interactively with no password as new user
            login -p -f  "${USER_NAME}"
        fi
    fi
}

#
# If --debug is passed as the first argument, enable debug.
#
if [ "$1" = "--debug" ];then
    set -x
    shift
fi

#
# Gather arguments and set action flags for processing after
# all parsing is done. The only functions that should get called
# from here are ones that take no arguments.

while [[ $# -gt 0 ]]
do
    # Ignore any unrecognized terms. Given this is invoked directly by
    # the due script, they are more likely a future feature than user error
    term="$1"
    case $term in
        -n|--username )
            USER_NAME="$2"
            shift
            ;;

        -i|--userid )
            USER_ID="$2"
            shift
            ;;

        --groupid )
            GROUP_ID="$2"
            shift
            ;;

        --groupname )
            GROUP_NAME="$2"
            shift
            ;;

        --command )
            # if a command was passed in, it's now the rest of these arguments
            # get --command off the list
            shift
            COMMAND_LIST="$@"
            # parsing stops here
            break
            ;;

        --docker-group-id )
            # If this container is configured to run other
            # containers, its docker group ID has to match
            # the host system's docker group ID.
            HOST_DOCKER_GID="$2"
            shift
            ;;

    esac
    shift
done

# If this container is going to run other Docker containers,
# it has to be invoked with --privileged, and mount the host's
# /dev and /var/run/docker.sock directories, which does allow
# the container to modify those directories.
# The container's Group ID of it's install of Docker also has
# to match the host's, so..
if [ -e /usr/bin/docker ];then
    # Oh, Docker is installed IN the container.
    # Was a group ID passed? Otherwise don't mention it.
    if [ "$HOST_DOCKER_GID" != "" ];then
        # Store the message for later
        DOCKER_GID_MESSAGE="| config : Container docker group ID set to $HOST_DOCKER_GID"
        fxnEC groupmod -g "$HOST_DOCKER_GID" docker || exit 1
    fi
fi


# If an image-specific /etc/hosts file was present for creaton,
# append its entries at run time. Docker will replace the /etc/hosts
# at run time, so this re-applies what the author intended to be there.
# Typical use would be to handle hostname resolution issues for
#  the container
if [ -e /due-configuration/filesystem/etc/hosts ];then
    # If the changes are not there yet, append them
    diff /due-configuration/filesystem/etc/hosts /etc/hosts \
        | grep '>' > /dev/null  && {
        sudo bash -c "cat /due-configuration/filesystem/etc/hosts >> /etc/hosts"
    }
fi

# at the user to the container
fxnAddUserInContainer

# If there's a command, run it, or just log in
fxnRunAsUser "$COMMAND_LIST"
