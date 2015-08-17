#!/usr/bin/env ruby

require 'rubygems'
require 'json'
require 'set'
require 'pp'
require 'resolv'

$replicaSet = "<%= instance_tag %>" # puppet will fill this in with the correct replicaset tag for this cluster


$exitStatus = 0  # Nagios style: 2 for error, 1 for warning
Signal.trap('EXIT') do
  if $! and not $!.is_a? SystemExit then
    exit 2  # i.e. default to 2 on uncaught exceptions
  end
end

def warn(problem)
  $exitStatus = 1 if $exitStatus == 0
  STDERR.puts "WARNING: #{problem}"
end

def error(problem)
  $exitStatus = 2
  STDERR.puts "DISASTER: #{problem}"
end

def valid_ip?(s)
  s =~ Resolv::IPv4::Regex ? true : false
end

def clean_mongo_json(mongo_crap)
  JSON.parse(mongo_crap.gsub(/ISODate\((.*?)\)/, '\1').gsub(/Timestamp\((.*?)\s*,\s*(.*?)\)/, '\1'))
end

def mongo_query(src)
  clean_mongo_json `mongo local --quiet --eval 'printjson(#{src})'`
end

def openMongo
   $pipe = IO.popen('mongo local --quiet', 'r+')
end

def writeMongoCommand(command)
   $pipe.puts(command)
end

def flushCloseMongo
   $pipe.close_write
   puts $pipe.read
end


# Fetch AWS instance info (for instances matching all our env tags)
#
def fetchInstanceInfo
  tags = `euca-describe-tags --filter 'resource-type=instance' --filter 'key=Replicaset'`

  $dbInstances = []
  tags.each_line do |l|
    match = l.match( /TAG\t+(\S+)\t+instance\t+Replicaset\t+(\S+)/i ) or next
    id = match[1]
    rsvars = match[2].downcase.split(',')
    if rsvars[0] == $replicaSet then
      $dbInstances << { :id => id, :role => rsvars[1] }
    end
  end

  $dbInstances.each do |i|
    instance = `euca-describe-instances '#{i[:id]}'`.lines.find{|l| l.match /^INSTANCE/i}

    i[:state] = instance.split("\t")[5] or raise("Failed to find current health of instance #{i[:id]}, skipping it")

    if i[:state] == "running" then # recently terminated instances will hang around for an hour, and their tags still get picked up
      i[:ip] = instance.split("\t")[17] or raise("Failed to find IP address of instance #{i[:id]}")
      raise "euca provided invalid IP '#{i[:ip]} for instance #{i[:id]}" unless valid_ip? i[:ip]
      i[:az] = instance.split("\t")[11] or raise("Failed to find availability zone of instance #{i[:id]}")
    end
  end
end

# Fetch Mongo's replica set info
#
def fetchRSInfo
  rsStatus = mongo_query('rs.status()')
  rsConf = mongo_query('rs.conf()')

  $rsMembers = {}  # Mongo 'name' => Hash of info
  rsStatus['members'].each do |m|
    $rsMembers[m['name']] = i = {
      :name => m['name'],
      :state => m['stateStr'],
      :health => m['health'],
      :id => m['_id'],
      :self => m['self'] || false,
    }
    i[:host],i[:port] = m['name'].split(':')
  end
  rsConf['members'].each_with_index do |m,idx|
    record = $rsMembers[m['host']]
    record[:tags] = m['tags']
    record[:priority] = m['priority']
    record[:conf_idx] = idx
  end
end

isMaster = mongo_query('db.isMaster()')['ismaster']
unless isMaster
  puts 'Not master. Nothing to do!'
  exit
end

# Initial data gathering and informative output
#
fetchInstanceInfo
puts; puts "AWS instance info:"
pp $dbInstances

fetchRSInfo
puts; puts "Mongo RS info:"
pp $rsMembers


# If we alter the Mongo config we'll have to re-read it and start again...
#
class RSConfigUpdated < Exception; end
$configUpdates = 0

# Do some work!
#
begin
  $rsMembers.each_value do |m|
    i = $dbInstances.find {|i| i[:ip]==m[:host]}
    unless i
      warn "The replica set member #{m[:name]} seems to be dead (or not a correctly tagged AWS instance)."
      next
    end

    if m[:tags].nil?
      puts "Tagging replica set member #{m[:name]} (#{i[:id]}) with AZ #{i[:az]}."
      puts "[INFO] c.members[#{m[:conf_idx]}].tags={\"all\":\"all\", \"az\":\"#{i[:az]}\"}"

      openMongo
      writeMongoCommand('c=rs.conf()')
      writeMongoCommand("c.members[#{m[:conf_idx]}].tags={\"all\":\"all\", \"az\":\"#{i[:az]}\"}")
      writeMongoCommand('rs.reconfig(c)')
      flushCloseMongo
      raise RSConfigUpdated

    else
      unless m[:tags]['all']=='all'
        warn "The replica set member #{m[:name]} isn't tagged with {all:all}."
      end
      unless m[:tags]['az']==i[:az]
        warn "The replica set member #{m[:name]} isn't tagged with the correct availability zone (#{m[:az]})."
      end
    end  
  end

  $dbInstances.each do |i|
    existingMember = $rsMembers.values.find {|m| m[:host]==i[:ip]}
    unless existingMember
      if valid_ip?(i[:ip]) then
        case i[:role]
        when "primary"
          nodeRole = "priority: 3,"
        when "hidden"
          nodeRole = "priority: 0, hidden: true,"
        else
          nodeRole = "priority: 1,"
        end

        puts "Adding new instance #{i[:ip]} (#{i[:name]}) to replica set!"
        newId = $rsMembers.values.map{|m| m[:id]}.max + 1
        puts "[INFO] rs.add({_id:#{newId}, host:\"#{i[:ip]}:27017\", #{nodeRole} tags: {\"all\":\"all\", \"az\":\"#{i[:az]}\"}})"
        mongo_query("rs.add({_id:#{newId}, host:\"#{i[:ip]}:27017\", #{nodeRole} tags: {\"all\":\"all\", \"az\":\"#{i[:az]}\"}})")
        raise RSConfigUpdated
      end
    end
  end

rescue RSConfigUpdated
  $configUpdates += 1
  raise "Excessive config updates have been made -- perhaps they aren't working? Perhaps Mongo isn't fully setup on a new instance yet" if $configUpdates > 9
  fetchRSInfo
  retry
end

exit $exitStatus
