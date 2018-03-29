# Hyper-V Storage Analysis
![alt text](https://github.com/WillyMoselhy/Hyper-V-Storage-Analysis/raw/master/Hyper-V%20Power%20BI.png "Sample Power BI report")
First you download the script and Power BI template.

Second, make sure you run the script on a workstation where the VMM and Hyper-V PowerShell modules are available. You should also have Power BI Desktop installed!

Once done you need to adjust the script to meet your environment as follows,
1.	Provide a VMM Server Name
2.	Provide list of CSV Roles, for example if you name your OS volume Hyper-V_OS_01, then the entry should be "*OS*" = "Operating System" CSVs that do not match are given the “Other” role.
3.	By default, the script saves its output under the current folder, you can change that by editing the last few lines.
4.	Run the script, it will take some time depending on your environment size.
5.	Open the Power BI Template and edit the queries to point to the saved CSV files from script.

Now refresh the data and review all the tabs to see details about your CSVs.
