#
# Copyright 2011-2013, Dell
# Copyright 2013-2014, SUSE LINUX Products GmbH
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

class ProvisionerService < ServiceObject
  def initialize(thelogger)
    super(thelogger)
    @bc_name = "provisioner"
  end

  class << self
    def role_constraints
      {
        "provisioner-server" => {
          "unique" => false,
          "count" => 1,
          "admin" => true,
          "exclude_platform" => {
            "windows" => "/.*/"
          }
        },
        "provisioner-base" => {
          "unique" => false,
          "count" => -1,
          "admin" => true
        }
      }
    end
  end

  def create_proposal
    @logger.debug("Provisioner create_proposal: entering")
    base = super
    @logger.debug("Provisioner create_proposal: exiting")
    base
  end

  def validate_proposal_after_save proposal
    proposal["attributes"]["provisioner"]["packages"].each do |platform, packages|
      packages.each do |package|
        unless Crowbar::Validator::PackageNameValidator.new.validate(package)
          validation_error("Package \"#{package}\" for \"#{platform}\" is not a valid package name.")
        end
      end
    end

    validate_one_for_role proposal, "provisioner-server"

    super
  end

  def transition(inst, name, state)
    @logger.debug("Provisioner transition: entering for #{name} for #{state}")

    role = RoleObject.find_role_by_name "provisioner-config-#{inst}"

    #
    # If the node is discovered, add the provisioner base to the node
    #
    if state == "discovered"
      @logger.debug("Provisioner transition: discovered state for #{name} for #{state}")
      db = Proposal.where(barclamp: "provisioner", name: inst).first

      #
      # Add the first node as the provisioner server
      #
      if role.override_attributes["provisioner"]["elements"]["provisioner-server"].nil?
        @logger.debug("Provisioner transition: if we have no provisioner add one: #{name} for #{state}")
        add_role_to_instance_and_node("provisioner", inst, name, db, role, "provisioner-server")

        # Reload the roles
        db.reload
        role = RoleObject.find_role_by_name "provisioner-config-#{inst}"
      end

      @logger.debug("Provisioner transition: Make sure that base is on everything: #{name} for #{state}")
      result = add_role_to_instance_and_node("provisioner", inst, name, db, role, "provisioner-base")

      if !result
        @logger.error("Provisioner transition: existing discovered state for #{name} for #{state}: Failed")
        return [400, "Failed to add role to node"]
      end

      if ENV["HAVE_CHEF_WEBUI"] == "true"
        # Set up the client url
        role = RoleObject.find_role_by_name "provisioner-config-#{inst}"

        # Get the server IP address
        server_ip = nil
        ["provisioner-server"].each do |element|
          tnodes = role.override_attributes["provisioner"]["elements"][element]
          next if tnodes.nil? or tnodes.empty?
          tnodes.each do |n|
            next if n.nil?
            node = NodeObject.find_node_by_name(n)
            pub = node.get_network_by_type("public")
            if pub and pub["address"] and pub["address"] != ""
              server_ip = pub["address"]
            else
              server_ip = node.get_network_by_type("admin")["address"]
            end
          end
        end

        unless server_ip.nil?
          node = NodeObject.find_node_by_name(name)
          node.crowbar["crowbar"] = {} if node.crowbar["crowbar"].nil?
          node.crowbar["crowbar"]["links"] = {} if node.crowbar["crowbar"]["links"].nil?
          node.crowbar["crowbar"]["links"]["Chef"] = "http://#{server_ip}:4040/nodes/#{node.name}"
          node.save
        end
      end
    end
    if state == "hardware-installing"
      role = RoleObject.find_role_by_name "provisioner-config-#{inst}"
      db = Proposal.where(barclamp: "provisioner", name: inst).first
      add_role_to_instance_and_node("provisioner",inst,name,db,role,"provisioner-bootdisk-finder")

      # ensure target platform is set before we claim a disk for boot OS
      node = NodeObject.find_node_by_name(name)
      if node[:target_platform].nil? or node[:target_platform].empty?
        node[:target_platform] = NodeObject.default_platform
        node.save
      end
    end

    if state == "reset"
      node = NodeObject.find_node_by_name(name)
      # clean up state capturing attributes on the node that are not likely to be the same
      # after a reset.
      if node["crowbar_wall"]["claimed_disks"]
        @logger.debug("Provisioner transition: clearing claimed disks for reset")
        node["crowbar_wall"]["claimed_disks"] = Mash.new
      else
        @logger.debug("Provisioner transition: claimed disks for reset node is empty")
      end

      ["boot_device"].each { |key |
        node["crowbar_wall"][key] = nil if (node["crowbar_wall"][key] rescue nil)
      }
      node.save
    end

    if state == "delete"
      # BA LOCK NOT NEEDED HERE.  NODE IS DELETING
      node = NodeObject.find_node_by_name(name)
      node.crowbar["state"] = "delete-final"
      node.save
    end

    #
    # test state machine and call chef-client if state changes
    #
    node = NodeObject.find_node_by_name(name)
    if ! node
      @logger.error("Provisioner transition: leaving #{name} for #{state}: Node not found")
      return [404, "Failed to find node"]
    end
    unless node.admin? or role.default_attributes["provisioner"]["dhcp"]["state_machine"][state].nil?
      # All non-admin nodes call single_chef_client if the state machine says to.
      @logger.info("Provisioner transition: Run the chef-client locally")
      system("sudo -i /opt/dell/bin/single_chef_client.sh")
    end
    @logger.debug("Provisioner transition: exiting for #{name} for #{state}")
    [200, { name: name }]
  end

  def load_repository_bag
    bag = Chef::DataBag.load("crowbar/repositories") rescue nil
    if bag.nil?
      @logger.debug("Creating repositories data bag")
      bag = Chef::DataBagItem.new
      bag.data_bag "crowbar"
      bag["id"] = "repositories"
      bag.save
    end
    bag
  end

  def synchronize_repositories(platforms)
    bag = load_repository_bag

    platforms.each do |platform, arches|
      arches.each do |arch, repos|
        repos.each do |repo, active|
          case active.to_i
          when 0
            disable_repository(platform, arch, repo, bag)
          when 1
            enable_repository(platform, arch, repo, bag)
          end
        end
      end
    end
  end

  def enable_all_repositories
    @logger.debug("Enabling all repositories.")
    bag = load_repository_bag
    Crowbar::Repository.check_all_repos.each do |repo|
      enable_repository(repo.platform, repo.arch, repo.id, bag)
    end
  end

  def disable_all_repositories
    @logger.debug("Disabling all repositories.")
    bag = load_repository_bag
    bag.keys.each do |platform|
      next if platform == "id"
      bag.delete(platform)
    end
    bag.save
  end

  def enable_repository(platform, arch, repo, bag = nil)
    bag = load_repository_bag if bag.nil?

    repo_object = Crowbar::Repository.where(platform: platform, arch: arch, repo: repo).first
    if repo_object.nil?
      message = "#{repo} repository for #{platform} / #{arch} does not exist."
      @logger.debug(message)
      return [404, message]
    end

    code = 200
    message = ""

    repo_id = repo_object.id
    @logger.debug("ID for #{repo} is #{repo_id}") if repo_id != repo

    if repo_object.available?
      bag[platform] ||= {}
      bag[platform][arch] ||= {}
      repo_hash = repo_object.to_databag_hash
      if bag[platform][arch][repo_id] != repo_object.to_databag_hash
        @logger.debug("Setting #{repo_id} repository for #{platform} / #{arch} as active.")
        bag[platform][arch][repo_id] = repo_hash
        bag.save
      else
        @logger.debug("#{repo_id} repository for #{platform} / #{arch} is already active.")
      end
    else
      message = "Cannot set #{repo_id} repository for #{platform} / #{arch} as active."
      @logger.debug(message)
      if bag.fetch(platform, {}).fetch(arch, {}).key? repo_id
        @logger.debug("Forcefully disabling #{repo_id} repository for #{platform} / #{arch}.")
        disable_repository(platform, arch, repo_id, bag)
      end

      code = 403
    end

    [code, message]
  end

  def disable_repository(platform, arch, repo, bag = nil)
    bag = load_repository_bag if bag.nil?

    repo_object = Crowbar::Repository.where(platform: platform, arch: arch, repo: repo).first
    if repo_object.nil?
      message = "#{repo} repository for #{platform} / #{arch} does not exist."
      @logger.debug(message)
      return [404, message]
    end

    repo_id = repo_object.id
    @logger.debug("ID for #{repo} is #{repo_id}") if repo_id != repo

    if bag.fetch(platform, {}).fetch(arch, {}).key? repo_id
      @logger.debug("Setting #{repo_id} repository for #{platform} / #{arch} as inactive.")
      bag[platform][arch].delete(repo_id)
      bag[platform].delete(arch) if bag[platform][arch].empty?
      bag.delete(platform) if bag[platform].empty?
      bag.save
    else
      @logger.debug("#{repo_id} repository for #{platform} / #{arch} is already inactive.")
    end

    [200, ""]
  end
end
