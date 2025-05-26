# kvm_backup
Backup scripts for KVM virtual machines

# Overview

Simple shell scripts to perform backup of KVM virtual machines.  Runs from cron on your KVM host(s).

Supported backup destinations include local disk path, remote NFS share, another remote KVM host.

# Scenario 1 - Backup to local disk

This option is useful if you only have a single KVM host and no other available network storage, but provides little redundancy against hardware failure.

Each VM has its own cron entry, The backup process is:
1) Shutdown VM   (these are all "cold" backups for consistency)
2) Dump XML configuration to a file
3) Copy QCOW2 virtual disk files to specified filesystem location
4) Start VM

# Scenario 2 - Backup to NFS share

This option is essentially the same process as the previous option, but the backups go to an NFS-mounted filesystem instead of a local filesystem.  

This provides hardware redundancy, but since these are all "cold" backups, and local disk is usually faster than network, each VM will have a longer outage during hte cold backup.

In this scenario, it is assumed that the backups are sent to a NAS or some other network storage providing an NFS export.  It is assumed that the KVM host already has the NFS filesystem mounted onto a local mount point.

Each VM has its own cron entry, The backup process is:
1) Shutdown VM   (these are all "cold" backups for consistency)
2) Dump XML configuration to a file
3) Copy QCOW2 virtual disk files to specified filesystem location
4) Start VM


# Scenario 3 - Backup to alternate KVM host

This option is useful when you have multiple KVM hosts, and each host is a "warm standby" for the other.

For example, KVMHOST1 sends its backups to KVMHOST2, and vice versa.  

In the event of either host failing, last night's backups are already on the alternate host, so can quickly be brought back online.  

In this scenario, it is assumed that SSH key pair authentication is configured on each KVM host to allow automated SSH/SCP connections.

Each VM has its own cron entry, The backup process is:
1) Shutdown VM   (these are all "cold" backups for consistency)
2) Dump XML configuration to a file
3) Copy QCOW2 virtual disk files to remote KVM host using tar-over-ssh to preserve sparse files
4) Start VM


# Installation

Download the files to each KVM host
```
cd /tmp
git clone https://github.com/nickjeffrey/kvm_backup
cd kvmbackup
cp kvm_cold_backup.sh  /root
cp kvm_cold_backup.cfg /root
```

On the KVM host, create cron jobs for each VM you want to backup.  Try to stagger the backups to avoid resource contention.
Adjust the cron schedules as appropriate for your environment.
```
# crontab -l

# nightly backups of KVM virtual machines
1  3 * * * /root/vm_backup.sh MyVM001 >/dev/null 2>&1 
31 3 * * * /root/vm_backup.sh MyVM002 >/dev/null 2>&1 
1  4 * * * /root/vm_backup.sh MyVM003 >/dev/null 2>&1 
31 4 * * * /root/vm_backup.sh MyVM004 >/dev/null 2>&1 

```

Adjust the /root/kvm_cold_backup.cfg file as appropriate for your environment, following the examples in the file.
```
# This is the configuration file for the vm_backup.sh script
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

This readme file describes how to restore a backup created by the /root/vm_backup.sh.nicktest script.

The following commands should be run on the standby host:

1. Check to see if the virtual machine definition already exists:
   /bin/virsh list --all
   /bin/virsh dominfo $vm_name

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

You can choose any or all of the backup destinations, but it is highly recommended that you backup to a local disk directly on the KVM host, because these are "cold" backups taken while the VM is powered down.  Since you want to minimize the time the VM is down, copying to a local disk is typically faster than copying to a network-based location.

HINT: If you backup to a local disk, the script will automatically start the VM after the local disk backup is completed, and will then continue with the (optional) copies to a remote NFS share or alternate KVM host.  The backup destinations are controlled by these entries in the config file:
```
backup_to_local_dir=yes|no
backup_to_remote_nfs=yes|no
backup_to_remote_scp=yes|no
```

### Q: Can I mix and match my backup destinations?  So VM1 gets backed to to local disk and NFS, but VM2 gets backed up to a remote KVM host?

A: No, mixing and matching backup destinations on a per-VM basis is not supported.  But it could be with some effort, feel free to make a pull request.

