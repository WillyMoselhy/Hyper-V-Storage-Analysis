# Hyper-V Storage Analysis
![alt text](https://github.com/WillyMoselhy/Hyper-V-Storage-Analysis/raw/master/Hyper-V%20Power%20BI.png "Sample Power BI report")

Do you remember the VM you deleted last year and promised to keep its VHDs for a month just in case but never actually removed them? 

Did your colleague ask you to convert a VMDK to VHD but you never actually delete the VMDK from your CSVs? 

Did you know that setting your VMs stop action to Save State utilizes as much disk space as their assigned RAM?

These and other pesky space wasting files were the reason I decided to create a script for CSV garbage collection, and since I have been learning Power BI for a while, I used its mighty visualization powers to make it easy to find and squeeze those extra GBs.

Using the script and Power BI you get the following info about your Hyper-V storage,
* Storage analysis by CSV role, which you define in the script. More on that later.
* List of unknown files, like VMDK or any non-Hyper-V related data.
* List of Checkpoints either normal or left over from failed backups.
* List of VMs with Save State as stop action
* Recommendation for CSV sizing for optimal space considering expansion of dynamic disks, this includes expansion due to checkpoints.
* And so many other useful information I believe every Hyper-V admin should know about their environment.


First you download the script and Power BI template.

Second, make sure you run the script on a workstation where the VMM and Hyper-V PowerShell modules are available. You should also have Power BI Desktop installed!

Once done you need to adjust the script to meet your environment as follows,
1.	Provide a VMM Server Name
2.	Provide list of CSV Roles, for example if you name your OS volume Hyper-V_OS_01, then the entry should be "*OS*" = "Operating System" CSVs that do not match are given the “Other” role.
3.	By default, the script saves its output under the current folder, you can change that by editing the last few lines.
4.	Run the script, it will take some time depending on your environment size.
5.	Open the Power BI Template and edit the queries to point to the saved CSV files from script.

Now refresh the data and review all the tabs to see details about your CSVs.
