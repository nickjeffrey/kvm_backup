#!/bin/sh


# OUTSTANDING TASKS
# -----------------
# document how to configure a relay host in postfix so this script can send email alerts
# figure out how to stop the automatic overwrite on the remote host in the event of a problem on the primary host (ie in a failover situation)
# add error check to confirm NAS responds to ping
# add error check to confirm alternate KVM host responds to ping


# CHANGE LOG
# ----------
# 2023-08-26	njeffrey	Script created
# 2025-02-01	njeffrey	Bug fixes, add support for backing up multiple VMs
# 2025-05-25	njeffrey	Add support for backup to remote NFS
# 2025-05-26	njeffrey	Confirm target directory exists before copying files
# 2025-06-02	njeffrey	Add hostname to email subject line
# 2025-10-14	njeffrey	Confirm script is running as root


# NOTES
# -----
# This script will perform the following tasks:
#  - graceful VM shutdown
#  - export VM definition to XML file, copy *.qcow2 disk image file(s) to backup folder
#  - startup VM
#  - copy VM backup files to remote location
#
# It is assumed that the script runs from the root crontab on each KVM host.  For example:
# 1  3 * * 1 /root/kvm_cold_backup.sh vm1 1>/dev/null 2>&1  #backup KVM virtual machine
# 31 3 * * 1 /root/kvm_cold_backup.sh vm2 1>/dev/null 2>&1  #backup KVM virtual machine


# confirm script is running as root
if [ "$EUID" -ne 0 ]; then
  echo "ERROR: this script must be run as root"
  exit 1
fi


# Declare variables
host_name=`hostname -s`
tee="/bin/tee --append"

# Confirm required files exist
echo Checking for required files
which mail    || { echo Cannot find mail    ; exit 1;}
which rsync   || { echo Cannot find rsync   ; exit 1;}
which awk     || { echo Cannot find awk     ; exit 1;}
which tee     || { echo Cannot find tee     ; exit 1;}
which tar     || { echo Cannot find tar     ; exit 1;}
which virsh   || { echo Cannot find virsh   ; exit 1;}
which logger  || { echo Cannot find logger  ; exit 1;}
which dirname || { echo Cannot find dirname ; exit 1;}


# There should be a config file with a .cfg extension in the same folder as this script
# Get the absolute path to the directory this script is located in
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Source the config file relative to the script location
config_file="$SCRIPT_DIR/kvm_cold_backup.cfg"
if [[ ! -f "$config_file" ]]; then
   echo "ERROR: cannot find configuration file, please confirm the .cfg file is in the same directory as this script" 
   echo "ERROR: cannot find configuration file, please confirm the .cfg file is in the same directory as this script" | logger
   echo "ERROR: cannot find configuration file, please confirm the .cfg file is in the same directory as this script" | mail -s "$host_name:$0 backup job error" $sysadmin
   exit 1
fi
source "$config_file"


# Confirm that the environment variables have been sourced from the config file
echo "Environment variables sourced from config file $config_file:"
echo "  send_email_report==$send_email_report"
echo "  sysadmin=$sysadmin"
echo "  backup_to_local_dir=$backup_to_local_dir"
echo "  local_vmdir=$local_vmdir"
echo "  local_backupdir=$local_backupdir"
echo "  backup_to_remote_nfs=$backup_to_remote_nfs"
echo "  remote_nfs_backupdir=$remote_nfs_backupdir"
echo "  backup_to_remote_scp=$backup_to_remote_scp"
echo "  remote_host=$remote_host"
echo "  remote_scp_backupdir=$remote_scp_backupdir"
echo "  maxage_days=$maxage_days"


# sanity checks to ensure there are sane values in the config file
if [[ "$send_email_report" == "yes" ]] && [[ "$sysadmin" == "helpdesk@example.com" ]]; then
   echo "ERROR: please change the sysadmin=$sysadmin line in the config file $config_file to a valid email address" 
   echo "ERROR: please change the sysadmin=$sysadmin line in the config file $config_file to a valid email address" | logger
   echo "ERROR: please change the sysadmin=$sysadmin line in the config file $config_file to a valid email address" | mail -s "$host_name:$0 backup job error" $sysadmin
   exit 1
fi
if [[ "$send_email_report" == "yes" ]] && [[ "$sysadmin" == "" ]]; then
   echo "ERROR: no destination email address found, please set the sysadmin= line in the config file $config_file" 
   echo "ERROR: no destination email address found, please set the sysadmin= line in the config file $config_file" | logger
   echo "ERROR: no destination email address found, please set the sysadmin= line in the config file $config_file" mail -s "$host_name:$0 backup job error" $sysadmin
   exit 1
fi
if [[ "$backup_to_local_dir" == "no" ]] && [[ "$backup_to_remote_nfs" == "no" ]] && [[ "$backup_to_remote_scp" == "no" ]]; then
   echo "ERROR: no backup targets found.  You must enable local or NFS or SCP, please check the config file" 
   echo "ERROR: no backup targets found.  You must enable local or NFS or SCP, please check the config file" | logger
   echo "ERROR: no backup targets found.  You must enable local or NFS or SCP, please check the config file" | mail -s "$host_name:$0 backup job error" $sysadmin
   exit 1
fi
#
if [[ "$backup_to_local_dir" == "yes" ]] && [[ "$local_backupdir" == "" ]]; then
   echo "ERROR: local_backupdir variable is not defined in config file $config_file" 
   echo "ERROR: local_backupdir variable is not defined in config file $config_file" | logger
   echo "ERROR: local_backupdir variable is not defined in config file $config_file" | mail -s "$host_name:$0 backup job error" $sysadmin
   exit 1
fi
if [[ "$backup_to_local_dir" == "yes" ]] && [[ ! -d "$local_backupdir" ]]; then
   echo "ERROR: local backup directory $local_backupdir does not exist, please create this directory." 
   echo "ERROR: local backup directory $local_backupdir does not exist, please create this directory." | logger
   echo "ERROR: local backup directory $local_backupdir does not exist, please create this directory." | mail -s "$host_name:$0 backup job error" $sysadmin
   exit 1
fi
#
if [[ "$backup_to_remote_nfs" == "yes" ]] && [[ "$remote_nfs_backupdir" == "" ]]; then
   echo "ERROR: remote_nfs_backupdir variable is not defined in config file $config_file" 
   echo "ERROR: remote_nfs_backupdir variable is not defined in config file $config_file" | logger
   echo "ERROR: remote_nfs_backupdir variable is not defined in config file $config_file" | mail -s "$host_name:$0 backup job error" $sysadmin
   exit 1
fi
if [[ "$backup_to_remote_nfs" == "yes" ]] && [[ ! -d "$remote_nfs_backupdir" ]]; then
   echo "ERROR: remote NFS share not mounted on $remote_nfs_backupdir , please mount this remote NFS share." 
   echo "ERROR: remote NFS share not mounted on $remote_nfs_backupdir , please mount this remote NFS share." | logger
   echo "ERROR: remote NFS share not mounted on $remote_nfs_backupdir , please mount this remote NFS share." | mail -s "$host_name:$0 backup job error" $sysadmin
   exit 1
fi



# Figure out the current date and time 
yyyymmdd=`date "+%Y%m%d"`
date_stamp=`date "+%Y-%m-%d %H:%M:%S"`


# Confirm the remote backup target is reachable via ping and SSH login
# to be written....


#
# Confirm a VM name was provided as a command line parameter
#
# Figure out the name of the VM to be backed up, which was provided as the $1 parameter of the script
vm_name=unknown
if [[ -z "$1" ]]; then
   echo ERROR: Please provide name of VM to be backed up.  For example: $0 vm_name  | logger
   echo ERROR: Please provide name of VM to be backed up.  For example: $0 vm_name  | mail -s "$host_name:$0 backup job error" $sysadmin
   exit 1
else
   vm_name=$1
fi


#
# Create the logfile
#
logfile=/tmp/$vm_name.backup.log
test -f $logfile && rm -f $logfile 
if [[ -f "$logfile" ]]; then
   echo ERROR: could not delete old version of logfile $logfile , Please check permissions. | logger
   echo ERROR: could not delete old version of logfile $logfile , Please check permissions. | mail -s "$host_name:$0 backup job error for $vm_name" $sysadmin
   exit 1
fi
touch $logfile
if [[ ! -f "$logfile" ]]; then
   echo ERROR: could not create logfile $logfile , Please check permissions. 
   echo ERROR: could not create logfile $logfile , Please check permissions. | logger
   echo ERROR: could not create logfile $logfile , Please check permissions. | mail -s "$host_name:$0 backup job error for $vm_name" $sysadmin
   exit 1
fi
echo Starting backup of virtual machine $vm_name from $0 script at $date_stamp | $tee $logfile
echo "Environment variables sourced from config file $config_file:"            | $tee $logfile
echo "  sysadmin=$sysadmin"                                                    | $tee $logfile
echo "  backup_to_local_dir=$backup_to_local_dir"                              | $tee $logfile
echo "  local_backupdir=$local_backupdir"                                      | $tee $logfile
echo "  backup_to_remote_nfs=$backup_to_remote_nfs"                            | $tee $logfile
echo "  remote_nfs_backupdir=$remote_nfs_backupdir"                            | $tee $logfile
echo "  backup_to_remote_scp=$backup_to_remote_scp"                            | $tee $logfile
echo "  remote_host=$remote_host"                                              | $tee $logfile
echo "  remote_scp_backupdir=$remote_scp_backupdir"                            | $tee $logfile
echo ' '                                                                       | $tee $logfile



# create a readme file on the local machine that describes how to perform a restore
# this file is initially created in /tmp, will be copied to other locations later
readme_txt=/tmp/$vm_name.howtorestore.txt
test -f $readme_txt && rm -f $readme_txt
echo ' ' | $tee $logfile
echo Creating readme file with restore instructions at $readme_txt | $tee $logfile
echo This readme file describes how to restore a backup created by the $0 script on $host_name   > $readme_txt
echo ' '                                                                                        >> $readme_txt
echo 'The following commands should be run on the standby host: '                               >> $readme_txt
echo ' '                                                                                        >> $readme_txt
echo '1. Check to see if the virtual machine definition already exists: '                       >> $readme_txt
echo '   /bin/virsh list --all'                                                                 >> $readme_txt  
echo "   /bin/virsh dominfo $vm_name"                                                           >> $readme_txt  
echo ' '                                                                                        >> $readme_txt
echo '2. If the virtual machine definition already exists, please delete it: '                  >> $readme_txt
echo "   /bin/virsh undefine $vm_name"                                                          >> $readme_txt
echo ' '                                                                                        >> $readme_txt
echo "3. It is highly preferred that the directory paths be identical on all KVM hosts."        >> $readme_txt
echo "   If the directory paths are not identical on the source and targer machines,"           >> $readme_txt
echo "   you must manually edit the $vm_name.xml file before the next step."                    >> $readme_txt
echo ' '                                                                                        >> $readme_txt
echo '4. Create the virtual machine definition: '                                               >> $readme_txt
echo "   /bin/virsh define --file $local_backupdir/$vm_name/$yyyymmdd/$vm_name.xml"             >> $readme_txt
echo ' '                                                                                        >> $readme_txt
echo '5. If the *.qcow2 file is gzipped, uncompress the file: '                                 >> $readme_txt
echo "   cd $local_backupdir/$vm_name/$yyyymmdd "                                               >> $readme_txt
echo '   find . -type f -name "*.qcow2.gz" -exec gunzip {} \; '                                 >> $readme_txt
echo ' '                                                                                        >> $readme_txt
echo '6. Copy the *.qcow2 disk image file to the appropriate directory: '                       >> $readme_txt
echo "   cp $local_backupdir/$vm_name/$yyyymmdd/*.qcow2 $local_vmdir/ "                         >> $readme_txt
echo ' '                                                                                        >> $readme_txt
echo '7. If desired, startup the virtual machine. NOTE: due to duplicate MAC addresses,'        >> $readme_txt
echo '   do not start up the standby VM if the primary VM is still running!'                    >> $readme_txt
echo "   /bin/virsh start $vm_name "                                                            >> $readme_txt
echo "   sleep 30 "                                                                             >> $readme_txt
echo '   /bin/virsh list --all '                                                                >> $readme_txt
echo "   /bin/virsh dominfo $vm_name "                                                          >> $readme_txt  
echo ' '                                                                                        >> $readme_txt



#
# Power down the VM
#
# confirm VM name is correct
# Note that we use grep with the ^$ anchors to avoid greedy matches of similar hostnames
vm_exists=unknown
/bin/virsh dominfo $vm_name | grep ^Name | grep -i $vm_name && vm_exists=yes
/bin/virsh dominfo $vm_name | grep ^Name | grep -i $vm_name || vm_exists=no
if [[ "$vm_exists" == "yes" ]]; then
   echo Confirmed that VM $vm_name exists | $tee $logfile
fi
if [[ "$vm_exists" == "no" ]]; then
   echo "ERROR: cannot find VM $vm_name , please confirm this is a valid name with: virsh list --all" | $tee $logfile
   echo "ERROR: cannot find VM $vm_name , please confirm this is a valid name with: virsh list --all" | mail -s "$host_name:$0 backup job error for $vm_name" $sysadmin
   exit
fi
if [[ "$vm_exists" == "unknown" ]]; then
   echo "ERROR: cannot determine the names of running VMs , please check with: virsh list --all" | $tee $logfile
   echo "ERROR: cannot determine the names of running VMs , please check with: virsh list --all" | mail -s "$host_name:$0 backup job error" $sysadmin
   exit
fi
#
# confirm current VM state is "running", then try to shutdown
#
vm_state=unknown
vm_restart=unknown
/bin/virsh dominfo $vm_name | grep ^State: | grep "running"  && vm_state=running
/bin/virsh dominfo $vm_name | grep ^State: | grep "shut off" && vm_state=shutoff
if [[ "$vm_state" == "shutoff" ]]; then
   echo Warning: VM $vm_name is not currently in the running state.  This script will not start the VM after the backup is complete. | $tee $logfile
   vm_restart=no
fi
if [[ "$vm_state" == "running" ]]; then
   date_stamp=`date "+%Y-%m-%d %H:%M:%S"`
   echo Confirmed that VM $vm_name is running, attempting to shutdown gracefully at $date_stamp | $tee $logfile
   vm_restart=yes
   /bin/virsh shutdown $vm_name 
fi
#
# give the machine 5 minutes to gracefully shutdown
#
/bin/virsh dominfo $vm_name | grep ^State: | grep running && ( echo Waiting for $vm_name to gracefully shutdown... ; sleep 60)
/bin/virsh dominfo $vm_name | grep ^State: | grep running && ( echo Waiting for $vm_name to gracefully shutdown... ; sleep 60)
/bin/virsh dominfo $vm_name | grep ^State: | grep running && ( echo Waiting for $vm_name to gracefully shutdown... ; sleep 60)
/bin/virsh dominfo $vm_name | grep ^State: | grep running && ( echo Waiting for $vm_name to gracefully shutdown... ; sleep 60)


# If the machine is still running after 5 minutes, try to shutdown again with the --mode acpi flag
/bin/virsh dominfo $vm_name | grep ^State: | grep "running"  && vm_state=running
/bin/virsh dominfo $vm_name | grep ^State: | grep "shut off" && vm_state=shutoff
if [[ "$vm_state" == "running" ]]; then
   date_stamp=`date "+%Y-%m-%d %H:%M:%S"`
   echo Warning: VM $vm_name is still running, attempting to shutdown gracefully with --mode acpi parameter at $date_stamp | $tee $logfile
   /bin/virsh shutdown $vm_name --mode acpi
   /bin/virsh dominfo $vm_name | grep ^State: | grep running && ( echo Waiting for $vm_name to gracefully shutdown... ; sleep 60)
   /bin/virsh dominfo $vm_name | grep ^State: | grep running && ( echo Waiting for $vm_name to gracefully shutdown... ; sleep 60)
   /bin/virsh dominfo $vm_name | grep ^State: | grep running && ( echo Waiting for $vm_name to gracefully shutdown... ; sleep 60)
   /bin/virsh dominfo $vm_name | grep ^State: | grep running && ( echo Waiting for $vm_name to gracefully shutdown... ; sleep 60)
   /bin/virsh dominfo $vm_name | grep ^State: | grep running && ( echo Waiting for $vm_name to gracefully shutdown... ; sleep 60)
fi


# Generate a warning if the VM did not shutdown gracefully 
vm_state=unknown
/bin/virsh dominfo $vm_name | grep ^State: | grep "running"  && vm_state=running
/bin/virsh dominfo $vm_name | grep ^State: | grep "shut off" && vm_state=shutoff
if [[ "$vm_state" == "running" ]]; then
   date_stamp=`date "+%Y-%m-%d %H:%M:%S"`
   echo ERROR: Cannot perform graceful shutdown of VM $vm_name , cancelling backup at $date_stamp | $tee $logfile
   echo ERROR: Cannot perform graceful shutdown of VM $vm_name , cancelling backup at $date_stamp | mail -s "$host_name:$0 backup job error for $vm_name" $sysadmin
   exit 1
fi
if [[ "$vm_state" == "unknown" ]]; then
   echo ERROR: Cannot determine state of VM $vm_name , please investigate | $tee $logfile
   echo ERROR: Cannot determine state of VM $vm_name , please investigate | mail -s "$host_name:$0 backup job error for $vm_name" $sysadmin
   exit 1
fi
if [[ "$vm_state" == "shutoff" ]]; then
   date_stamp=`date "+%Y-%m-%d %H:%M:%S"`
   echo $vm_restart | grep "no"  && echo VM $vm_name was already powered down, continuing with cold backup at $date_stamp | $tee $logfile
   echo $vm_restart | grep "yes" && echo Confirmed VM $vm_name successful shutdown  at $date_stamp | $tee $logfile
fi






#
# Run this section if backup_to_local_dir=yes 
#
if [[ "$backup_to_local_dir" == "yes" ]]; then
   #
   # confirm target directory exists
   echo ' ' | $tee $logfile
   echo ' ' | $tee $logfile
   echo ' ' | $tee $logfile
   echo Performing backup to local directory $local_backupdir/$vm_name/$yyyymmdd/ | $tee $logfile
   echo Confirming target folder exists | $tee $logfile
   cmd="   test -d $local_backupdir/$vm_name/$yyyymmdd || mkdir -p $local_backupdir/$vm_name/$yyyymmdd"
   echo "$cmd"  | $tee $logfile
   eval "$cmd" 
   #
   if [[ ! -d "$local_backupdir/$vm_name/$yyyymmdd" ]]; then
      echo ERROR: could not create local backup directory $local_backupdir/$vm_name/$yyyymmdd 
      echo ERROR: could not create local backup directory $local_backupdir/$vm_name/$yyyymmdd | logger
      echo ERROR: could not create local backup directory $local_backupdir/$vm_name/$yyyymmdd | mail -s "$host_name:$0 backup job error for $vm_name" $sysadmin
      exit 1
   fi
   #
   # confirm the target directory is writeable
   #
   echo testing > $local_backupdir/$vm_name/$yyyymmdd/testfile.tmp
   if [[ ! -f "$local_backupdir/$vm_name/$yyyymmdd/testfile.tmp" ]]; then
      echo ERROR: could not create file $local_backupdir/$vm_name/$yyyymmdd/testfile.tmp , Please check permissions. 
      echo ERROR: could not create file $local_backupdir/$vm_name/$yyyymmdd/testfile.tmp , Please check permissions. | logger
      echo ERROR: could not create file $local_backupdir/$vm_name/$yyyymmdd/testfile.tmp , Please check permissions. | mail -s "$host_name:$0 backup job error for $vm_name" $sysadmin
      exit 1
   fi
   test -f "$local_backupdir/$vm_name/$yyyymmdd/testfile.tmp" && rm -f "$local_backupdir/$vm_name/$yyyymmdd/testfile.tmp"
   #
   # delete local backup copies more than $maxage_days days old
   #
   echo Deleting any local backups older than $maxage_days days from $local_backupdir/$vm_name/ | $tee $logfile
   cmd="   find $local_backupdir/$vm_name -type f -mtime +$maxage_days -exec echo rm {} \;"     | $tee $logfile
   echo "$cmd"  | $tee $logfile
   eval "$cmd" 
   # delete any empty subdirectories after deleting old files
   cmd="   find $local_backupdir/$vm_name -type d -empty -print -delete"
   echo "$cmd"  | $tee $logfile
   eval "$cmd" 
   #
   # confirm target directory exists, just in case we deleted it in the previous step
   echo Confirming target folder exists | $tee $logfile
   cmd="   test -d $local_backupdir/$vm_name/$yyyymmdd || mkdir -p $local_backupdir/$vm_name/$yyyymmdd"
   echo "$cmd"  | $tee $logfile
   eval "$cmd" 
   #
   #
   # save the VM disk images to a backup location on the local machine
   #
   /bin/virsh dominfo $vm_name | grep ^State: | grep "running"  && vm_state=running
   /bin/virsh dominfo $vm_name | grep ^State: | grep "shut off" && vm_state=shutoff
   if [[ "$vm_state" == "shutoff" ]]; then
      #
      # delete any old versions of the backup files
      #
      test -f $local_backupdir/$vm_name/$yyyymmdd/$vm_name.xml   && echo Deleting previous version of $local_backupdir/$vm_name/$yyyymmdd/$vm_name.xml   && rm -f $local_backupdir/$vm_name/$yyyymmdd/$vm_name.xml
      test -f $local_backupdir/$vm_name/$yyyymmdd/$vm_name.qcow2 && echo Deleting previous version of $local_backupdir/$vm_name/$yyyymmdd/$vm_name.qcow2 && rm -f $local_backupdir/$vm_name/$yyyymmdd/$vm_name.qcow2
      #
      # create new backups
      #
      echo ' ' | $tee $logfile
      echo Creating XML dump of VM configuration to $local_backupdir/$vm_name/$yyyymmdd/$vm_name.xml | $tee $logfile
      cmd="   /bin/virsh dumpxml $vm_name > $local_backupdir/$vm_name/$yyyymmdd/$vm_name.xml"
      echo "$cmd"  | $tee $logfile
      eval "$cmd" 
      # 
      # figure out the filenames for the virtual disk image(s) assigned to this VM
      #
      echo ' ' | $tee $logfile
      echo "Copying virtual disk files to local backup location $local_backupdir/$vm_name/$yyyymmdd/*.qcow2" | $tee $logfile
      cat $local_backupdir/$vm_name/$yyyymmdd/$vm_name.xml | grep "source file" | grep qcow2 | awk -v backupdir="$local_backupdir/$vm_name/$yyyymmdd" -F "'" '{print "\t cp " $2, backupdir}' | sh -x 
      find $local_backupdir/$vm_name/$yyyymmdd -type f -name "*.qcow2" | $tee $logfile
      #
      # find any disks in a libvirt storage pool that do not provide the full path.  For example:
      # virsh dumpxml MyHostName | grep "<source pool>"
      # <source pool='default' volume='MyDemoDisk.qcow2'/>
      cat $local_backupdir/$vm_name/$yyyymmdd/$vm_name.xml | grep "source pool" | grep qcow2 | awk -F "'" '{print $4}' | while read diskname ; do for pool in $(virsh pool-list --all --name); do virsh vol-list "$pool" | grep "^ $diskname" | awk -v backupdir="$local_backupdir/$vm_name/$yyyymmdd" '{print "cp " $2, backupdir}' | sh -x  ; done ; done | $tee $logfile
   fi
   #
   # copy the readme and logfile from /tmp
   #
   cp $readme_txt $local_backupdir/$vm_name/$yyyymmdd
   cp $logfile    $local_backupdir/$vm_name/$yyyymmdd
   #
   # XXXX xxxx this section needs fixing up because it assumes the QCOW2 filenames
   # confirm the local backup copy was created
   vm_backup_status=unknown
   if [[ ! -f $local_backupdir/$vm_name/$yyyymmdd/$vm_name.xml ]]; then
      echo ERROR: could not create XML file $local_backupdir/$vm_name/$yyyymmdd/$vm_name.xml | $tee $logfile
      echo ERROR: could not create XML file $local_backupdir/$vm_name/$yyyymmdd/$vm_name.xml | mail -s "$host_name:$0 backup job error" $sysadmin
      vm_backup_status=fail
   fi
   if [[ ! -f $local_backupdir/$vm_name/$yyyymmdd/$vm_name.qcow2 ]]; then
      echo ERROR: could not create QCOW2 file $local_backupdir/$vm_name/$yyyymmdd/$vm_name.qcow2 | $tee $logfile
      echo ERROR: could not create QCOW2 file $local_backupdir/$vm_name/$yyyymmdd/$vm_name.qcow2 | mail -s "$host_name:$0 backup job error" $sysadmin
      vm_backup_status=fail
   fi
   test -f $local_backupdir/$vm_name/$yyyymmdd/$vm_name.xml && test -f $local_backupdir/$vm_name/$yyyymmdd/$vm_name.qcow2 && vm_backup_status=ok
   #
   # Start the VM after completing the local backup, because any NFS or SCP backups can use the local backups that were just completed
   #
   echo ' ' | $tee $logfile
   if [[ "$vm_state" == "shutoff" ]]; then
      if [[ "$vm_restart" == "no" ]]; then
         echo Skipping restart of VM because VM was not already running prior to backup | $tee $logfile
      fi
      if [[ "$vm_restart" == "yes" ]]; then
         date_stamp=`date "+%Y-%m-%d %H:%M:%S"`
         echo Starting VM $vm_name at $date_stamp | $tee $logfile
         /bin/virsh start $vm_name
         sleep 5
      fi
   fi
   vm_state=unknown
   /bin/virsh dominfo $vm_name | grep ^State: | grep "running"  && vm_state=running
   /bin/virsh dominfo $vm_name | grep ^State: | grep "shut off" && vm_state=shutoff
fi



# -----------------------------------------
# copy backups to remote SSH/SCP host
# -----------------------------------------
if [[ "$backup_to_remote_scp" == "no"  ]]; then
   echo ' ' | $tee $logfile
   echo "Remote SCP backup target not defined in config file, skipping copy to remote SCP server" | $tee $logfile
fi
if [[ "$backup_to_remote_scp" == "yes" ]]; then
   echo ' ' | $tee $logfile
   echo ' ' | $tee $logfile
   echo ' ' | $tee $logfile
   date_stamp=`date "+%Y-%m-%d %H:%M:%S"`
   echo Starting backup to remote SSH/SCP host $remote_host:$local_backupdir/$vm_name/$yyyymmdd/ at $date_stamp | $tee $logfile
   #
   # confirm target directory exists on remote host 
   echo "Confirming target directory exists" | $tee $logfile
   cmd="ssh $remote_host \"test -d $remote_scp_backupdir/$vm_name/$yyyymmdd || mkdir -p $remote_scp_backupdir/$vm_name/$yyyymmdd\""
   echo "   $cmd"  | $tee $logfile
   eval "   $cmd" 
   #
   # delete remote backups more than $maxage_days days old
   echo Deleting any remote backups older than $maxage_days days from $remote_host:$remote_scp_backupdir/$vm_name | $tee $logfile
   cmd="ssh $remote_host \"find $remote_scp_backupdir/$vm_name -type f -mtime +$maxage_days -print -exec rm {} \;\""
   echo "   $cmd"  | $tee $logfile
   eval "   $cmd" 
   # delete any empty subdirectories after deleting old files
   # use -mindepth 1 parameter to delete subdirectories, but not the top-level $vm_name directory
   cmd="ssh $remote_host \"find $remote_scp_backupdir/$vm_name -mindepth 1 -type d -empty -delete\""
   echo "   $cmd"  | $tee $logfile
   eval "   $cmd" 
   #
   # confirm target directory exists on remote host, because the previous cleanup step may have deleted it
   echo "Confirming target directory exists, just in case the previous step deleted it" | $tee $logfile
   cmd="ssh $remote_host \"test -d $remote_scp_backupdir/$vm_name/$yyyymmdd || mkdir -p $remote_scp_backupdir/$vm_name/$yyyymmdd\""
   echo "   $cmd"  | $tee $logfile
   eval "   $cmd" 
   #
   # If we have a local backup copy already, copy files from local backup directory to remote SSH/SCP server
   # This section runs if backup_to_local_dir=yes
   # If this section runs, the VM has already been powered up after making a backup to a local directory
   #
   if [[ "$backup_to_local_dir" == "yes" ]] && [[ "$backup_to_remote_scp" == "yes" ]]; then
      echo Copying local backup files from $local_backupdir/$vm_name/$yyyymmdd/ to remote SSH/SCP backup target $remote_host:$remote_scp_backupdir/$vm_name/$yyyymmdd/ | $tee $logfile
      find $local_backupdir/$vm_name/$yyyymmdd -type f | $tee $logfile
      # for the tiny *.xml and *.txt and *.log files, we will just copy them over as-is
      scp $local_backupdir/$vm_name/$yyyymmdd/*.xml $remote_host:$remote_scp_backupdir/$vm_name/$yyyymmdd
      scp $local_backupdir/$vm_name/$yyyymmdd/*.txt $remote_host:$remote_scp_backupdir/$vm_name/$yyyymmdd
      scp $local_backupdir/$vm_name/$yyyymmdd/*.log $remote_host:$remote_scp_backupdir/$vm_name/$yyyymmdd
      #
      # For the large QCOW2 files, use tar-over-ssh instead of scp because tar can keep the thin provisioned sparse file without expanding to thick provisioning
      cd $local_backupdir/$vm_name/$yyyymmdd
      echo "Sending $local_backupdir/$vm_name/$yyyymmdd/*.qcow2" to remote host $remote_host via tar-over-ssh to preserve thin provisioning" | $tee $logfile
      tar -Scf - *.qcow2 | ssh $remote_host "tar -Sxf - -C $remote_scp_backupdir/$vm_name/$yyyymmdd/"
      date_stamp=`date "+%Y-%m-%d %H:%M:%S"`
      echo Finished copying backup to remote SSH/SCP host  at $date_stamp | $tee $logfile
   fi
   #
   # If we do NOT have a local backup copy already, copy files from local backup directory to remote SSH/SCP target
   # This section runs if backup_to_local_dir=no
   # If this section runs, the VM is still powered down, and is waiting for a cold backup of its virtual disk files to be copied over the network to a remote SSH/SCP host
   #
   if [[ "$backup_to_local_dir" == "no" ]] && [[ "$backup_to_remote_scp" == "yes" ]]; then
      echo Copying files to remote SSH/SCP backup target $remote_host:$remote_scp_backupdir/$vm_name/$yyyymmdd/ | $tee $logfile
      #
      # for the tiny *.xml and *.txt and *.log files, we will just copy them over as-is
      xml_dumpfile=/tmp/$vm_name.xmldump.tmp
      cmd="   /bin/virsh dumpxml $vm_name > $xml_dumpfile"                                             ; echo "$cmd" | $tee $logfile ; eval "$cmd"
      cmd="   scp $xml_dumpfile   $remote_host:$remote_scp_backupdir/$vm_name/$yyyymmdd/$vm_name.xml"  ; echo "$cmd" | $tee $logfile ; eval "$cmd"
      cmd="   scp $readme_txt     $remote_host:$remote_scp_backupdir/$vm_name/$yyyymmdd"               ; echo "$cmd" | $tee $logfile ; eval "$cmd"
      cmd="   scp $logfile        $remote_host:$remote_scp_backupdir/$vm_name/$yyyymmdd"               ; echo "$cmd" | $tee $logfile ; eval "$cmd"
      #
      #
      # For the large QCOW2 files, use tar-over-ssh instead of scp because tar can keep the thin provisioned sparse file without expanding to thick provisioning
      echo "Performing tar-over-ssh cold backup, copying virtual disk files to $remote_host:$remote_scp_backupdir/$vm_name/$yyyymmdd/*.qcow2" | $tee $logfile
      #
      # figure out the filenames for the virtual disk image(s) assigned to this VM
      cat $xml_dumpfile | grep "source file" | grep qcow2  | awk -F"'" '{print $2}' | while read -r fullpath; do
         parentdir=$(dirname "$fullpath")
         filename=$(basename "$fullpath")
         tar_create="tar -C \"$parentdir\" -Scf - \"$filename\""
         tar_extract="tar -Sxf - -C \"$remote_scp_backupdir/$vm_name/$yyyymmdd\""
         cmd="$tar_create | ssh $remote_host $tar_extract"
         echo "   $cmd"  | $tee $logfile
         eval "   $cmd" 
      done 
      #
      # find any disks in a libvirt storage pool that do not provide the full path.  For example:
      # virsh dumpxml MyHostName | grep "<source pool>"
      # <source pool='default' volume='MyDemoDisk.qcow2'/>
      cat $xml_dumpfile | grep "source pool" |  grep qcow2 | awk -F"'" '{print $4}' | while read -r diskname; do
         echo "Searching for storage pool volume: $diskname"
         for pool in $(virsh pool-list --all --name); do
            fullpath=$(virsh vol-list "$pool" | awk -v name="$diskname" '$1 == name {print $2}')
            if [ -n "$fullpath" ]; then
               echo "Found $diskname in pool $pool at $fullpath"
               parentdir=$(dirname "$fullpath")
               filename=$(basename "$fullpath")
               tar_create="tar -C \"$parentdir\" -Scf - \"$filename\""
               tar_extract="tar -Sxf - -C \"$remote_scp_backupdir/$vm_name/$yyyymmdd\""
               cmd="$tar_create | ssh $remote_host $tar_extract"
               echo "   $cmd" | $tee $logfile
               eval "   $cmd"
            fi
         done
      done
      date_stamp=`date "+%Y-%m-%d %H:%M:%S"`
      echo Finished copying backup to remote SSH/SCP host at $date_stamp | $tee $logfile
   fi
   # 
   # get the latest version of the logfile
   scp $logfile $remote_host:$remote_scp_backupdir/$vm_name/$yyyymmdd
fi



# -----------------------------------------
# copy backups to remote NFS host
# -----------------------------------------
if [[ "$backup_to_remote_nfs" == "no"  ]]; then
   echo ' ' | $tee $logfile
   echo "Remote NFS backup target not defined, skipping copy to remote NFS server" | $tee $logfile
fi
if [[ "$backup_to_remote_nfs" == "yes" ]]; then
   echo ' ' | $tee $logfile
   echo ' ' | $tee $logfile
   echo ' ' | $tee $logfile
   date_stamp=`date "+%Y-%m-%d %H:%M:%S"`
   echo Found remote NFS backup target at mount point $remote_nfs_backupdir | $tee $logfile
   #
   # confirm NFS mount point exists
   #
   if [[ ! -d "$remote_nfs_backupdir" ]]; then
      echo "ERROR: remote NFS share is not mounted on $remote_nfs_backupdir , please ensure remote directory is exported and mounted on this KVM server" | $tee $logfile
      echo "ERROR: remote NFS share is not mounted on $remote_nfs_backupdir , please ensure remote directory is exported and mounted on this KVM server" | mail -s "$host_name:$0 backup job error" $sysadmin
   fi
   #
   # confirm we can create a subdirectory on the remote NFS host
   #
   if [[ -d "$remote_nfs_backupdir" ]]; then
      if [[ ! -d "$remote_nfs_backupdir/$vm_name/$yyyymmdd" ]]; then
         echo Creating target directory $remote_nfs_backupdir/$vm_name/$yyyymmdd | $tee $logfile
         mkdir -p $remote_nfs_backupdir/$vm_name/$yyyymmdd
      fi
      if [[ ! -d "$remote_nfs_backupdir/$vm_name/$yyyymmdd" ]]; then
         echo "ERROR: could not create remote NFS directory $remote_nfs_backupdir/$vm_name/$yyyymmdd , please check permissions" | $tee $logfile
         echo "ERROR: could not create remote NFS directory $remote_nfs_backupdir/$vm_name/$yyyymmdd , please check permissions" | mail -s "`hostname` $host_name:$0 backup job error" $sysadmin
      fi
      #
      # delete any remote NFS backup copies more than $maxage_days days old
      #
      if [[ ! -d "$remote_nfs_backupdir/$vm_name" ]]; then
         echo Deleting any remote NFS backups older than $maxage_days days from $remote_nfs_backupdir/$vm_name/ | $tee $logfile
         find $remote_nfs_backupdir/$vm_name -type f -mtime +$maxage_days -exec echo rm {} \; | $tee $logfile
         find $remote_nfs_backupdir/$vm_name -type f -mtime +$maxage_days -exec      rm {} \;
         # delete any empty subdirectories after deleting old files
         find $remote_nfs_backupdir/$vm_name -type d -empty -print -delete
      fi
   fi
   #
   # confirm target directory exists, just in case we deleted it in the previous step
   echo Confirming target folder exists | $tee $logfile
   cmd="   test -d $remote_nfs_backupdir/$vm_name/$yyyymmdd || mkdir -p $remote_nfs_backupdir/$vm_name/$yyyymmdd"
   echo "$cmd"  | $tee $logfile
   eval "$cmd" 
   #
   #
   # If we have a local backup copy already, copy files from local backup directory to remote NFS target
   # This section runs if backup_to_local_dir=yes
   # If this section runs, the VM has already been powered up after making a backup to a local directory
   #
   if [[ "$backup_to_local_dir" == "yes" ]] && [[ -d "$remote_nfs_backupdir/$vm_name/$yyyymmdd" ]]; then
      echo Copying files from local backup $local_backupdir/$vm_name/$yyyymmdd/ to remote NFS backup target $remote_nfs_backupdir/$vm_name/$yyyymmdd/ | $tee $logfile
      # for the tiny *.xml and *.txt and *.log files, we will just copy them over as-is
      cmd="   cp $local_backupdir/$vm_name/$yyyymmdd/*.xml $remote_nfs_backupdir/$vm_name/$yyyymmdd" ; echo "$cmd" | $tee $logfile ; eval "$cmd"
      cmd="   cp $local_backupdir/$vm_name/$yyyymmdd/*.txt $remote_nfs_backupdir/$vm_name/$yyyymmdd" ; echo "$cmd" | $tee $logfile ; eval "$cmd"
      cmd="   cp $local_backupdir/$vm_name/$yyyymmdd/*.log $remote_nfs_backupdir/$vm_name/$yyyymmdd" ; echo "$cmd" | $tee $logfile ; eval "$cmd"
      #
      # For the large QCOW2 files, use tar-over-ssh instead of scp because tar can keep the thin provisioned sparse file without expanding to thick provisioning
      echo Copying large virtual disk images using tar to keep thin provisioned sparse files
      cmd="   cd $local_backupdir/$vm_name/$yyyymmdd ; tar -Scf - *.qcow2 | tar -Sxf - -C \"$remote_nfs_backupdir/$vm_name/$yyyymmdd/\""
      echo "$cmd"  | $tee $logfile
      eval "$cmd" 
      echo Getting list of files copied to remote NFS location
      find $remote_nfs_backupdir/$vm_name/$yyyymmdd -type f | $tee $logfile
      date_stamp=`date "+%Y-%m-%d %H:%M:%S"`
      echo Finished copying backup to remote NFS share at $date_stamp | $tee $logfile
   fi
   #
   # If we do NOT have a local backup copy already, copy files from local backup directory to remote NFS target
   # This section runs if backup_to_local_dir=no
   # If this section runs, the VM is still powered down, and is waiting for a cold backup of its virtual disk files to be copied over the network to a remote NFS mount
   #
   if [[ "$backup_to_local_dir" == "no" ]] && [[ -d "$remote_nfs_backupdir/$vm_name/$yyyymmdd" ]]; then
      echo Performing cold backup to remote NFS backup target $remote_nfs_backupdir/$vm_name/$yyyymmdd/ | $tee $logfile
      # for the tiny *.xml and *.txt and *.log files, we will just copy them over as-is
      if [[ -d "$remote_nfs_backupdir/$vm_name/$yyyymmdd" ]]; then
         /bin/virsh dumpxml $vm_name > $remote_nfs_backupdir/$vm_name/$yyyymmdd/$vm_name.xml
         cp $readme_txt                $remote_nfs_backupdir/$vm_name/$yyyymmdd
         cp $logfile                   $remote_nfs_backupdir/$vm_name/$yyyymmdd
      fi
      #
      # For the large QCOW2 files, use tar instead of just cp because tar can keep the thin provisioned sparse file without expanding to thick provisioning
      echo "Copying virtual disk files to $remote_nfs_backupdir/$vm_name/$yyyymmdd/*.qcow2" | $tee $logfile
      #
      # figure out the filenames for the virtual disk image(s) assigned to this VM
      cat $remote_nfs_backupdir/$vm_name/$yyyymmdd/$vm_name.xml | grep "source file" | grep qcow2  | awk -F"'" '{print $2}' | while read -r fullpath; do
         parentdir=$(dirname "$fullpath")
         filename=$(basename "$fullpath")
         tar_create="tar -C \"$parentdir\" -Scf - \"$filename\""
         tar_extract="tar -Sxf - -C \"$remote_nfs_backupdir/$vm_name/$yyyymmdd\""
         cmd="$tar_create | $tar_extract"
         echo "   $cmd"  | $tee $logfile
         eval "$cmd" 
      done 
      #
      # find any disks in a libvirt storage pool that do not provide the full path.  For example:
      # virsh dumpxml MyHostName | grep "<source pool>"
      # <source pool='default' volume='MyDemoDisk.qcow2'/>
      #cat $remote_nfs_backupdir/$vm_name/$yyyymmdd/$vm_name.xml | grep "source pool" | grep qcow2 | awk -F "'" '{print $4}' | while read diskname ; do for pool in $(virsh pool-list --all --name); do virsh vol-list "$pool" | grep "^ $diskname" | awk -v backupdir="$remote_nfs_backupdir/$vm_name/$yyyymmdd" '{print "cp " $2, backupdir}' | sh -x  ; done ; done | $tee $logfile
      cat $remote_nfs_backupdir/$vm_name/$yyyymmdd/$vm_name.xml | grep "source pool" |  grep qcow2 | awk -F"'" '{print $4}' | while read -r diskname; do
         echo "Searching for storage pool volume: $diskname"
         for pool in $(virsh pool-list --all --name); do
            fullpath=$(virsh vol-list "$pool" | awk -v name="$diskname" '$1 == name {print $2}')
            if [ -n "$fullpath" ]; then
               echo "Found $diskname in pool $pool at $fullpath"
               parentdir=$(dirname "$fullpath")
               filename=$(basename "$fullpath")
               tar_create="tar -C \"$parentdir\" -Scf - \"$filename\""
               tar_extract="tar -Sxf - -C \"$remote_nfs_backupdir/$vm_name/$yyyymmdd\""
               cmd="$tar_create | $tar_extract"
               echo "   $cmd" | $tee $logfile
               eval "$cmd"
            fi
         done
      done
   fi
   # 
   # get the latest version of the logfile
   cp $logfile $remote_nfs_backupdir/$vm_name/$yyyymmdd
fi




# Commented out 2025-02-01 because the *.qcow2 files are already thin provisioned sparse files
## To save disk space, compress the local backup copy of the *.qcow2 file
## 
## This step can take a long time
#if [[ "$vm_backup_status" == "ok" ]]; then
#   date_stamp=`date "+%Y-%m-%d %H:%M:%S"`
#   echo Compressing backup file $backupdir/$vm_name.qcow2 at $date_stamp | $tee $logfile
#   test -f $local_backupdir/$vm_name/$yyyymmdd/$vm_name.qcow2.gz && (echo Removing old version of $local_backupdir/$vm_name/$yyyymmdd/$vm_name.qcow2.gz                    ; rm -f $local_backupdir/$vm_name/$yyyymmdd/$vm_name.qcow2.gz)
#   test -f $local_backupdir/$vm_name/$yyyymmdd/$vm_name.qcow2    && (echo Compressing backup file $local_backupdir/$vm_name/$yyyymmdd/$vm_name.qcow2, please be patient... ; gzip  $local_backupdir/$vm_name/$yyyymmdd/$vm_name.qcow2   )
#   date_stamp=`date "+%Y-%m-%d %H:%M:%S"`
#   echo Finished compressing backup file $local_backupdir/$vm_name/$yyyymmdd/$vm_name.qcow2 at $date_stamp | $tee $logfile
#   echo Copying compressed backup file to $remote_host:$local_backupdir/$vm_name/$yyyymmdd/$vm_name.qcow2.gz at $date_stamp | $tee $logfile
#   test -f $local_backupdir/$vm_name/$yyyymmdd/$vm_name.qcow2.gz && scp $local_backupdir/$vm_name/$yyyymmdd/$vm_name.qcow2.gz $remote_host:$local_backupdir/$vm_name/$yyyymmdd/$vm_name.qcow2.gz
#   date_stamp=`date "+%Y-%m-%d %H:%M:%S"`
#   echo Finished copying compressed backup file to $remote_host:$local_backupdir/$vm_name/$yyyymmdd/$vm_name.qcow2.gz at $date_stamp | $tee $logfile
#fi 


# Check to see if the VM needs to be started
if [[ "$vm_state" == "shutoff" ]]; then
   if [[ "$vm_restart" == "no" ]]; then
      echo Skipping restart of VM because VM was not already running prior to backup | $tee $logfile
   fi
   if [[ "$vm_restart" == "yes" ]]; then
      date_stamp=`date "+%Y-%m-%d %H:%M:%S"`
      echo Starting VM $vm_name at $date_stamp | $tee $logfile
      /bin/virsh start $vm_name
      echo Waiting 30 seconds for VM to start
      sleep 30
      /bin/virsh dominfo $vm_name | grep ^State: | grep "running"  && vm_state=running
      /bin/virsh dominfo $vm_name | grep ^State: | grep "shut off" && vm_state=shutoff
   fi
fi
if [[ "$vm_state" == "shutoff" ]] && [[ "$vm_restart" == "yes" ]]; then
   echo "ERROR: VM $vm_name failed to start after cold backup, please investigate" 
   echo "ERROR: VM $vm_name failed to start after cold backup, please investigate" | $tee $logfile
   echo "ERROR: VM $vm_name failed to start after cold backup, please investigate" | mail -s "$host_name:$0 backup job error" $sysadmin
fi

# Send email report to sysadmin
echo ' ' | $tee $logfile
date_stamp=`date "+%Y-%m-%d %H:%M:%S"`
echo Backup complete at $date_stamp | $tee $logfile
echo Backup details saved to logfile $logfile | $tee $logfile
echo For restore instructions, please refer to $vm_name.howtorestore.txt in the same folder as the backup. | $tee $logfile
echo Sending backup report via email to $sysadmin at $date_stamp | $tee $logfile
test -f $logfile && cat $logfile | mail -s "`hostname` backup report for $vm_name" $sysadmin

