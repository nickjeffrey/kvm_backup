# kvm_backup
Backup script for KVM virtual machines

# Overview

Simple shell scripts to perform backup of KVM virtual machines.  Runs from cron on your KVM host(s).

Supported backup destinations include local disk path, remote NFS share, another remote KVM host.

# Scenario 1 - Backup to local disk

This option is useful if you only have a single KVM host and no other available network storage, but provides little redundancy against hardware failure.

Each VM has its own cron entry, with the high-level steps looking similar to:
1) Shutdown VM   (these are all "cold" backups for consistency)
2) Dump XML configuration to a file
3) Copy QCOW2 virtual disk files to specified filesystem location
4) Start VM

# Scenario 2 - Backup to NFS share

This option is essentially the same process as the previous option, but the backups go to an NFS-mounted filesystem instead of a local filesystem.  

This provides hardware redundancy, but since these are all "cold" backups, and local disk is usually faster than network, each VM will have a longer outage during the cold backup.

In this scenario, it is assumed that the backups are sent to a NAS or some other network storage providing an NFS export.  It is assumed that the KVM host already has the NFS filesystem mounted onto a local mount point.

Each VM has its own cron entry, with the high-level steps looking similar to:
1) Shutdown VM   (these are all "cold" backups for consistency)
2) Dump XML configuration to a file
3) Copy QCOW2 virtual disk files to specified filesystem location
4) Start VM


# Scenario 3 - Backup to alternate KVM host

This option is useful when you have multiple KVM hosts, and each host is a "warm standby" for the other.

For example, KVMHOST1 sends its backups to KVMHOST2, and vice versa.  

In the event of either host failing, last night's backups are already on the alternate host, so can quickly be brought back online.  

In this scenario, it is assumed that SSH key pair authentication is configured on each KVM host to allow automated SSH/SCP connections.

Each VM has its own cron entry, with the high-level steps looking similar to:
1) Shutdown VM   (these are all "cold" backups for consistency)
2) Dump XML configuration to a file
3) Copy QCOW2 virtual disk files to remote KVM host using tar-over-ssh to preserve sparse files
4) Start VM


# Scenario 4 - Combinations of the above  

Depending on the availabilility of NAS storage or alternate KVM hosts in your environment, you can send backups to any or all of the above.

You can choose any or all of the backup destinations, but it is highly recommended that you backup to a local disk directly on the KVM host, because these are "cold" backups taken while the VM is powered down.

Since you want to minimize the time the VM is down, copying to a local disk is typically faster than copying to a network-based location.

HINT: If you backup to a local disk, the script will automatically start the VM after the local disk backup is completed, and will then continue with the (optional) copies to a remote NFS share or alternate KVM host.


# Installation

Download the files to each KVM host
```
cd /tmp
git clone https://github.com/nickjeffrey/kvm_backup
cd kvmbackup
cp kvm_cold_backup.cfg  /root/kvm_cold_backup.cfg
cp kvm_cold_backup.shg  /root/kvm_cold_backup.sh
chmod 755 /root/kvm_cold_backup.ksh
```

On the KVM host, create cron jobs for each VM you want to backup.  Try to stagger the backups to avoid resource contention.
Adjust the cron schedules as appropriate for your environment.
```
# crontab -l

# nightly backups of KVM virtual machines
1  3 * * * /root/vm_backup.sh myvm1 >/dev/null 2>&1 
31 3 * * * /root/vm_backup.sh myvm2 >/dev/null 2>&1 
1  4 * * * /root/vm_backup.sh myvm3 >/dev/null 2>&1 
31 4 * * * /root/vm_backup.sh myvm4 >/dev/null 2>&1 

1  5 * * 6 /root/vm_backup.sh myvm5 >/dev/null 2>&1  #only backup on Saturdays
31 5 * * 0 /root/vm_backup.sh myvm6 >/dev/null 2>&1  #only backup on Sundays
```

Adjust the /root/kvm_cold_backup.cfg file as appropriate for your environment, following the examples in the file.
```
# This is the configuration file for the kvm_cold_backup.sh script
# Edit the variables in this file to match your environment

# yes|no flag to send an email report showing the backup status
send_email_report=yes

# define the email address that reports should be sent to
sysadmin=helpdesk@example.com

# yes|no flag to enable backups to a local directory
# This is typically set to yes, because these are all "cold" backups while the VM is down,
# and copying files from one local directory to another local directory is typically much
# faster than copies over the network, which means the downtime for the VM is shortest with this option.
# If you do not have enough local disk space for backups, set this option to no ,
# but please note that the VM will be down until the virtual disk image files are copied to the remote
# backup location over the network, which may take a long time.
backup_to_local_dir=yes

# If backup_to_local_dir=yes, define the directory that local backups are sent to
# This may be left blank or commented out if backup_to_local_dir=no
local_backupdir=/var/lib/libvirt/images/backups

# yes|no flag to enable backups to an NFS-mounted directory
# If you have a NAS or NFS share in your environment that you can send backups to, set backup_to_remote_nfs=yes
# If set to yes, the NFS mount point must be mounted and available on the KVM host
backup_to_remote_nfs=yes

# The remote_nfs_backupdir is only required if the backup_to_remote_nfs=yes
# This is the local mount point on the KVM host
remote_nfs_backupdir=/var/lib/libvirt/images/nfsbackups

# yes|no flag to scp files to a remote host
# This is typically used if you have two KVM hosts, and want each host to send nightly backup copies to the other
# If set to yes, it is assumed that SSH key pairs are already configured
# If set to yes, it is assumed that the remote host has the same $local_backupdir directory structure as the source host
backup_to_remote_scp=yes
remote_scp_backupdir=/var/lib/libvirt/images/backups

# If backup_to_remote_scp=yes , each KVM host will have a partner.
# We assume SSH key pairs are already set up.
hostname | grep -q kvmhost1 && remote_host=kvmhost2.example.com
hostname | grep -q kvmhost2 && remote_host=kvmhost1.example.com
```


# How to restore

Each backup job will create a readme file in the same folder as the backup, detailing the commands required to perform a restore.  For example:

```
# cat /var/lib/libvirt/images/backups/myvm.howtorestore.txt

This readme file describes how to restore a backup created by the /root/kvm_cold_backup.sh script.

The following commands should be run on the standby host:

1. Check to see if the virtual machine definition already exists:
   /bin/virsh list --all
   /bin/virsh dominfo myvm

2. If the virtual machine definition already exists, please delete it:
   /bin/virsh undefine myvm

3. It is highly preferred that the directory paths be identical on all KVM hosts.
   If the directory paths are not identical on the source and targer machines,
   you must manually edit the myvm.xml file before the next step.

4. Create the virtual machine definition:
   /bin/virsh define --file /path/to/backup/myvm/yyyymmdd/myvm.xml

5. If the *.qcow2 file is gzipped, uncompress the file:
   cd /path/to/backup/myvm/yyyymmdd
   find . -type f -name "*.qcow2.gz" -exec gunzip {} \;

6. Copy the *.qcow2 disk image file to the appropriate directory:
   cp /path/to/backup/myvm/yyyymmdd/*.qcow2 /to/appropriate/location/

7. If desired, startup the virtual machine. NOTE: due to duplicate MAC addresses,
   do not start up the standby VM if the primary VM is still running!
   /bin/virsh start myvm
   /bin/virsh list --all
   /bin/virsh dominfo myvm
```

# Q & A

### Q: What backup destinations are supported?

A: Backups can be sent to a local filesystem, to an NFS-mounted filesystem on a NAS, or to an alternate "warm standby" KVM host.  

### Q: Is there a recommended backup destination?

You can choose any or all of the backup destinations, but it is highly recommended that you backup to a local disk directly on the KVM host, because these are "cold" backups taken while the VM is powered down.  

Since you want to minimize the time the VM is down, copying to a local disk is typically faster than copying to a network-based location.

HINT: If you backup to a local disk, the script will automatically start the VM after the local disk backup is completed, and will then continue with the (optional) copies to a remote NFS share or alternate KVM host.  The backup destinations are controlled by these entries in the config file:
```
backup_to_local_dir=yes|no
backup_to_remote_nfs=yes|no
backup_to_remote_scp=yes|no
```

### Q: Can I mix and match my backup destinations?  So VM1 gets backed to to local disk and NFS, but VM2 gets backed up to a remote KVM host?

A: No, mixing and matching backup destinations on a per-VM basis is not supported.  But it could be with some effort, feel free to make a pull request.


### Q: I cannot have any downtime for my virtual machines.  Is there a hot backup option?

A: Hot backup options exist, but are outside the scope of this script.  


### Q: How much disk space will I need for backups?

A: These are all full cold backups, no incrementals or differentials, so you will need the same amount of space as all your VMs, multiplied by the number of backup generations you want to keep.  Note that if your source virtual disk files are thin-provisioned sparse files, the backups will be as well.  You might also consider sending the backups to a deduplicating filesystem (ie NetApp, DataDomain, etc) for storage efficiencies.

### Q: How will I know if the backup succeeds?  Or how long the backup takes?

A: The backup job creates a verbose logfile, which which is (optionally) emailed to the sysadmin as a report of the backup status.  An example report is shown below:
```
Starting backup of virtual machine centos10test from /root/vm_backup.sh.nicktest script at 2025-05-25 02:42:05
Environment variables sourced from config file /root/vm_backup.cfg:
  sysadmin=janedoe@example.com
  backup_to_local_dir=no
  local_backupdir=/var/lib/libvirt/images/backups
  backup_to_remote_nfs=yes
  remote_nfs_backupdir=/var/lib/libvirt/images/nfsbackups
  backup_to_remote_scp=yes
  remote_host=kvmhost2.example.com
  remote_scp_backupdir=/var/lib/libvirt/images/backups
 
 
Creating readme file with restore instructions at /tmp/centos10test.howtorestore.txt
Confirmed that VM centos10test exists
Warning: VM centos10test is not currently in the running state. This script will not start the VM after the backup is complete.
VM centos10test was already powered down, continuing with cold backup at 2025-05-25 02:42:05
 
Starting backup to remote SSH/SCP host kvmhost2.example.com:/var/lib/libvirt/images/backups/centos10test/20250525/ at 2025-05-25 02:42:05
Confirming target directory exists
   ssh kvmhost2.example.com "test -d /var/lib/libvirt/images/backups/centos10test/20250525 || mkdir -p /var/lib/libvirt/images/backups/centos10test/20250525"
Deleting any remote backups older than 30 days from kvmhost2.example.com:/var/lib/libvirt/images/backups
   ssh kvmhost2.example.com "find /var/lib/libvirt/images/backups -type f -mtime +30 -print -exec rm {} \;"
   ssh kvmhost2.example.com "find /var/lib/libvirt/images/backups -type d -empty -delete"
Confirming target directory exists, just in case the previous step deleted it
   ssh kvmhost2.example.com "test -d /var/lib/libvirt/images/backups/centos10test/20250525 || mkdir -p /var/lib/libvirt/images/backups/centos10test/20250525"
Copying files to remote SSH/SCP backup target kvmhost2.example.com:/var/lib/libvirt/images/backups/centos10test/20250525/
   /bin/virsh dumpxml centos10test > /tmp/centos10test.xmldump.tmp
   scp /tmp/centos10test.xmldump.tmp   kvmhost2.example.com:/var/lib/libvirt/images/backups/centos10test/20250525/centos10test.xml
   scp /tmp/centos10test.howtorestore.txt     kvmhost2.example.com:/var/lib/libvirt/images/backups/centos10test/20250525
   scp /tmp/centos10test.backup.log        kvmhost2.example.com:/var/lib/libvirt/images/backups/centos10test/20250525
Performing tar-over-ssh cold backup, copying virtual disk files to kvmhost2.example.com:/var/lib/libvirt/images/backups/centos10test/20250525/*.qcow2
   tar -C "/var/lib/libvirt/images" -Scf - "centos10test.qcow2" | ssh kvmhost2.example.com tar -Sxf - -C "/var/lib/libvirt/images/backups/centos10test/20250525"
   tar -C "/var/lib/libvirt/images" -Scf - "MyDemoDisk.qcow2" | ssh kvmhost2.example.com tar -Sxf - -C "/var/lib/libvirt/images/backups/centos10test/20250525"
Finished copying backup to remote SSH/SCP host at 2025-05-25 02:42:27
 
Found remote NFS backup target at mount point /var/lib/libvirt/images/nfsbackups
Performing cold backup to remote NFS backup target /var/lib/libvirt/images/nfsbackups/centos10test/20250525/
Copying virtual disk files to /var/lib/libvirt/images/nfsbackups/centos10test/20250525/*.qcow2
   tar -C "/var/lib/libvirt/images" -Scf - "centos10test.qcow2" | tar -Sxf - -C "/var/lib/libvirt/images/nfsbackups/centos10test/20250525"
   tar -C "/var/lib/libvirt/images" -Scf - "MyDemoDisk.qcow2" | tar -Sxf - -C "/var/lib/libvirt/images/nfsbackups/centos10test/20250525"
Skipping restart of VM because VM was not already running prior to backup
 
Backup complete at 2025-05-25 02:42:35
Backup details saved to logfile /tmp/centos10test.backup.log
For restore instructions, please refer to centos10test.howtorestore.txt in the same folder as the backup.
Sending backup report via email to janedoe@example.com at 2025-05-25 02:42:35
```
