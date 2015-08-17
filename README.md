# update-replicasets
Update-replicasets is a Ruby script to manage members of a Mongo replicaset. 

It's designed for Mongo in AWS, as it uses an EC2 tag 'Replicaset' to identify instances as they become available. This tag is a string with a name for the replicaset, which should match $replicaSet within the script.
