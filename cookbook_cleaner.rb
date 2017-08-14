#!/usr/bin/env ruby

require 'chef'
require 'choice'
require 'json'

Choice.options do
  header ""
  header "Specific options:"

  option :int_conf  do
    short '-c'
    long  '--knife_conf=PATH_TO_KNIFE_RB'
    desc  'Knife config file to use for querying chef'
    default File.expand_path('~/.chef/knife.rb')
  end

  option :historical_versions do
    short '-h'
    long  '--historical-versions'
    desc  'Number of historical cookbook versions to keep'
    default  5
  end

  option :environment do
    short '-e'
    long  '--environment ENVIRONMENT'
    desc  'Email addresses to send report to'
    default  "production"
  end

  option :really_clean do
    long  '--really-clean'
    desc  'Actually delete old versions for real'
    default  false
  end

  option :verbose do
    short '-v'
    long  '--verbose'
    desc  'Actually delete old versions for real'
    default  false
  end
end

knife_config = Choice.choices[:int_conf]
historical_version_count = Choice.choices[:historical_versions]
environment = Choice.choices[:environment]
really_clean = Choice.choices[:really_clean]
verbose_mode = Choice.choices[:verbose]

# Create a Chef::Config object from the supplied knife.rb
Chef::Config.from_file(Choice.choices[:int_conf])

# Create a REST object for interacting with the Chef Server API
int_rest = Chef::REST.new(Chef::Config[:chef_server_url])

puts "************************************"
puts "*         Cookbook Cleaner         *"
puts "************************************"
puts ""
puts "Knife Configuration: #{knife_config}"
puts "Historical Cookbook Versions to Keep: #{historical_version_count}"
puts "Environment for constraint checking: #{environment}"
puts ""

# Load the environment and get the list of version constraints it contains
puts "Loading environment #{environment} to collect current version constraints"
env_object = Chef::Environment.load(environment)

# Strip out the "= " constraint operator from each constraint to leave us with a list of the version numbers contained in the environment
env_cookbook_versions = env_object.cookbook_versions.each{|cb_name, cb_constraint| cb_constraint.gsub!('= ','')}

# Load a list of all cookbooks on the Chef server and what versions exist for them
puts "Loading list of cookbooks from Chef server"
server_cookbooks = int_rest.get_rest("/cookbooks?num_versions=all")

puts ""

# Iterate over the list of cookbooks on the server
server_cookbooks.each do |cookbook_name,cookbook_data|

  # Get a list of versions for that cookbook and reverse the order since
  # chef returns cookbook versions as most-recent-first
  cookbook_versions = cookbook_data["versions"].map{|ver_data|  Chef::Version.new(ver_data["version"])}.reverse
  promoted_version = env_cookbook_versions[cookbook_name]

  # Print info about the cookbook
  puts "Cookbook: #{cookbook_name}"
  puts "Current Promoted Version: #{promoted_version}"

  # If we can find a promoted version in the environment for the current cookbook
  if promoted_version

    # Covert version number from environment into Chef::Version Object
    promoted_version = Chef::Version.new(promoted_version)
    puts "- Total Versions on Server: #{cookbook_versions.length}"

    # Use <=> operation of Chef::Version class to find versions older than the current promoted version
    # A value of -1 means that the LHS arg is 'older' than the RHS arg, ie an older version.
    deletion_candidates = cookbook_versions.select{|cb_ver| (cb_ver <=> promoted_version) == -1}

    # Make a list of the <historical_version_count> last versions, which we will keep
    to_be_kept = deletion_candidates[-historical_version_count..-1]

    # Make a list of the <historical_version_count> last versions, which we can delete
    to_be_deleted = deletion_candidates[0..(-historical_version_count)-1]

    puts "- Versions older than #{promoted_version}: #{deletion_candidates.length}"

    # If less versions are available to delete than we want to keep
    if deletion_candidates.length < historical_version_count

      # Print a message saying so.
      puts "- Keeping all versions as only #{cookbook_versions.length} versions on server"

    # Otherwise keep going
    else

      puts "- Keeping versions #{(to_be_kept).inspect}"

      puts "- Versions fitting deletion criteria: #{to_be_deleted.length || 0}"

      # If we're in verbose mode, print the full list of version numbers to delete
      if verbose_mode
        puts "- Deleting the following versions: "
        puts "#{to_be_deleted.inspect}"
      end

      # If the --really-clean option was passed, we want to actually delete candidate versions
      if really_clean

        # Iterate throught the collections of versions to delete
        to_be_deleted.each do |deletion_version|

          # And make a call to the Chef API to delete that version
          puts "-- Deleting #{cookbook_name} version #{deletion_version}"
          int_rest.delete_rest("cookbooks/#{cookbook_name}/#{deletion_version}")
        end

      # If --really-clean was *not* passed, just print a message and don't delete anything
      else
        puts "-- Skipping deletions as --really-clean not specified"
      end

    end
  # This means for whatever reason the cookbook hasn't been promoted, so we'll skip it.
  else
    puts "Cookbook not promoted, skipping..."
  end
  puts ""
end

