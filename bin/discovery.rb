#!/opt/puppet/bin/ruby
$LOAD_PATH << '/opt/asm-deployer/lib'
require "trollop"
require "json"
require "timeout"
require "pathname"
require "asm/util"
require "asm/os_inventory_run"

puppet_dir = File.join(Pathname.new(__FILE__).parent.parent,'lib','puppet')
require "%s/scaleio/transport" % [puppet_dir]

@opts = Trollop::options do
  opt :server, "ScaleIO gateway", :type => :string, :required => true
  opt :port, "ScaleIO gateway port", :default => 443
  opt :username, "ScaleIO gateway username", :type => :string, :required => true
  opt :password, "ScaleIO gateway password", :type => :string, :default => ENV["PASSWORD"]
  opt :os_username, "", :type => :string, :required => true
  opt :os_password_id, "Not used"
  opt :os_password, "", :type => :string, :default => ENV["OS_PASSWORD"]
  opt :timeout, "ScaleIO gateway connection timeout", :type => :integer, :default => 300, :required => false
  opt :credential_id, "credentials_id for the Gateway", :type => :string, :required => true
  opt :output, "Location of the file where facts file needs to be created", :type => :string, :required => false
end

def vxflexos_hostname
  flex_hostname = ""
  begin
    tcp_client = TCPSocket.new(@opts[:server], 443)
    ssl_context = OpenSSL::SSL::SSLContext.new
    ssl_context.verify_mode = OpenSSL::SSL::VERIFY_NONE
    ssl_client = OpenSSL::SSL::SSLSocket.new(tcp_client, ssl_context)
    ssl_client.connect
    cert = OpenSSL::X509::Certificate.new(ssl_client.peer_cert)
    ssl_client.sysclose
    tcp_client.close
    certprops = OpenSSL::X509::Name.new(cert.issuer).to_a
    flex_hostname = certprops.select { |name, data, type| name == "CN" }.first[1]
    puts "Flex hostname retrieved: %s" % flex_hostname
  rescue
    puts "Error gathering inventory for server: %s reason: %s" % [@opts[:server], $!.to_s]
    flex_hostname = "vxflexos-%s" % [@opts[:server]]
  end

  flex_hostname
end

def collect_scaleio_facts
  check_ssh_connection
  gateway_os_facts = collect_gateway_os_facts
  scaleio_package_info = gateway_os_facts["packages"]["EMC-ScaleIO-gateway"].first if gateway_os_facts && gateway_os_facts["packages"]

  facts = {:protection_domain_list => []}
  facts[:certname] = "scaleio-%s" % [@opts[:server]]
  facts[:name] = vxflexos_hostname
  facts[:update_time] = Time.now
  facts[:device_type] = "script"
  facts[:scaleio_rpm_version] = "DellEMC ScaleIO Version: R#{scaleio_package_info["version"]}.#{scaleio_package_info["release"]}" if scaleio_package_info
  facts[:gateway_ips] = gateway_os_facts["ansible_all_ipv4_addresses"] if gateway_os_facts
  facts[:os_facts] = gateway_os_facts

  # ScaleIO MDM is not configured
  # Need to return basic information
  if scaleio_cookie == "NO MDM"
    facts.merge!({
      :general => { "name" => vxflexos_hostname },
      :statistics => {},
      :sdc_list => [],
      :protection_domain_list => [],
      :fault_sets => []
    })

    return facts
  end

  scaleio_system = scaleio_systems[0]

  facts[:general] = scaleio_system
  facts[:general][:name] = facts[:name]
  facts[:statistics] = scaleio_system_statistics(scaleio_system)
  facts[:sdc_list] = scaleio_sdc(scaleio_system)
  protection_domains(scaleio_system).each do |protection_domain|
    accel_pool_info = protection_domain_acceleration_pool(protection_domain)
    pd = {:general => protection_domain,
          :statistics => protection_domain_statistics(protection_domain),
          :storage_pool_list => protection_domain_storage_pools(protection_domain),
          :sds_list => protection_domain_sdslist(protection_domain),
          :acceleration_pool => accel_pool_info,
          :acceleration_pool_devices => acceleration_pool_devices(accel_pool_info)}
    pd[:storage_pool_list].each do |storage_pool|
      storage_pool[:statistics] = storage_pool_statistics(storage_pool)
      storage_pool[:disk_list] = storage_pool_disks(storage_pool)
      storage_pool[:volume_list] = storage_pool_volumes(storage_pool)
    end
    facts[:protection_domain_list] << pd
  end
  facts[:fault_sets] = scaleio_faultsets(scaleio_system)
  facts
end

def collect_gateway_os_facts
  puts "Collecting gateway os inventory with Ansible on %s." %@opts[:server]
  begin
    output = ("/opt/Dell/ASM/cache/%s.json" % "Flex_os_gateway-#{@opts[:server]}")
    ASM::OSInventoryRun.logger=(Logger.new(STDOUT))
    gateway_os_inventory = ASM::OSInventoryRun.gather_red_hat_os_inventory([{:server => @opts[:server],
                                                                             :credential_id => @opts[:credential_id],
                                                                             :is_scaleio => true,
                                                                             :cache_output => output}])
    puts "Done with new inventory SVM Inventory for: %s" % @opts[:server] if gateway_os_inventory && !gateway_os_inventory.empty?
    return gateway_os_inventory.first if gateway_os_inventory && !gateway_os_inventory.empty?
    puts "Gateway inventory was empty for %s." % @opts[:server] if gateway_os_inventory && gateway_os_inventory.empty?
  rescue
    # Don't fail discovery if we cant get OS facts
    raise("Cannot get gateway OS facts with ansible for %s due to error: %s" % [@opts[:server], $!.message])
  end

  nil
end

def check_ssh_connection
  puts "Attempting to ssh to verify root credentials."
  begin
    result = ASM::Util.execute_script_via_ssh(@opts[:server], @opts[:os_username], @opts[:os_password], "ls")
    puts "SSH test result code: %s, result: %s, error msg: %s" % [result[:exit_code],result[:stdout],result[:stderr]] if result
  rescue
    puts "ERROR!! SSH test result code: %s, result: %s, error msg: %s" % [result[:exit_code],result[:stdout],result[:stderr]] if result
    raise
  end
end

def get_scaleio_version
  begin
    result = ASM::Util.execute_script_via_ssh(@opts[:server], @opts[:os_username], @opts[:os_password], "rpm -q EMC-ScaleIO-gateway")
    version = result[:stdout].scan(/EMC-ScaleIO-gateway-(.*\d+)\./).flatten.first if result
    return version.gsub(/-/, ".") if version
  rescue
    puts "ERROR!! Unable to get scaleio rpm version exit code: %s, result: %s, error msg: %s" % [result[:exit_code], result[:stdout], result[:stderr]] if result
    raise
  end

  nil
end

def scaleio_systems
  url = transport.get_url("api/types/System/instances")
  transport.post_request(url, {}, "get") || []
end

def scaleio_gateway_systems
  url = transport.get_url("api/configuration")
  transport.post_request(url, {}, "get") || []
end

def scaleio_system_statistics(scaleio_system)
  end_point = "/api/instances/System::%s/relationships/Statistics" % [scaleio_system["id"]]
  url = transport.get_url(end_point)
  transport.post_request(url, {}, "get") || []
end

def scaleio_sdc(scaleio_system)
  sdc_url = "/api/instances/System::%s/relationships/Sdc" % [scaleio_system["id"]]
  url = transport.get_url(sdc_url)
  transport.post_request(url, {}, "get") || []
end

def protection_domains(scaleio_system)
  pd_url = "/api/instances/System::%s/relationships/ProtectionDomain" % [scaleio_system["id"]]
  url = transport.get_url(pd_url)
  transport.post_request(url, {}, "get") || []
end

def protection_domain_statistics(protection_domain)
  end_point = "/api/instances/ProtectionDomain::%s/relationships/Statistics" % [protection_domain["id"]]
  url = transport.get_url(end_point)
  transport.post_request(url, {}, "get") || []
end

def protection_domain_storage_pools(protection_domain)
  sp_url = "/api/instances/ProtectionDomain::%s/relationships/StoragePool" % [protection_domain["id"]]
  url = transport.get_url(sp_url)
  transport.post_request(url, {}, "get") || []
end

def protection_domain_sdslist(protection_domain)
  sp_url = "/api/instances/ProtectionDomain::%s/relationships/Sds" % [protection_domain["id"]]
  url = transport.get_url(sp_url)
  transport.post_request(url, {}, "get") || []
end

def protection_domain_acceleration_pool(protection_domain)
  acc_url = "/api/instances/ProtectionDomain::%s/relationships/AccelerationPool" % [protection_domain["id"]]
  url = transport.get_url(acc_url)
  transport.post_request(url, {}, "get") || []
rescue
  []
end

def acceleration_pool_devices(accel_pool_info)
  return [] if accel_pool_info.empty?

  acc_pool_devices = []
  accel_pool_info.each do |accel_pool|
    accel_pool_id = accel_pool["id"]
    acc_url = "/api/instances/AccelerationPool::%s/relationships/Device" % [accel_pool_id]
    url = transport.get_url(acc_url)
    acc_pool_devices << transport.post_request(url, {}, "get") || []
  end

  acc_pool_devices
end

def storage_pool_volumes(storage_pool)
  sp_url = "/api/instances/StoragePool::%s/relationships/Volume" % [storage_pool["id"]]
  url = transport.get_url(sp_url)
  transport.post_request(url, {}, "get") || []
end

def storage_pool_statistics(storage_pool)
  end_point = "/api/instances/StoragePool::%s/relationships/Statistics" % [storage_pool["id"]]
  url = transport.get_url(end_point)
  transport.post_request(url, {}, "get") || []
end

def storage_pool_disks(storage_pool)
  sp_url = "/api/instances/StoragePool::%s/relationships/Device" % [storage_pool["id"]]
  url = transport.get_url(sp_url)
  transport.post_request(url, {}, "get") || []
end

def scaleio_faultsets(scaleio_system)
  faultset_url = "/api/types/FaultSet/instances?systemId=%s" % [scaleio_system["id"]]
  url = transport.get_url(faultset_url)
  transport.post_request(url, {}, "get") || []
end

def transport
  @transport ||= Puppet::ScaleIO::Transport.new(@opts)
end

def scaleio_cookie
  @scaleio_cookie ||= transport.get_scaleio_cookie
end

facts = {}
begin
  Timeout.timeout(@opts[:timeout]) do
    facts = collect_scaleio_facts.to_json
  end
rescue Timeout::Error
  puts "Timed out trying to gather ScaleIO Inventory"
  exit 1
rescue Exception => e
  puts "#{e}\n#{e.backtrace.join("\n")}"
  exit 1
else
  if facts.empty?
    puts "Could not get updated facts"
    exit 1
  else
    puts "Successfully gathered inventory."
    if @opts[:output]
      File.write(@opts[:output], JSON.pretty_generate(JSON.parse(facts)))
    else
      results ||= {}
      scaleio_cache = "/opt/Dell/ASM/cache"
      Dir.mkdir(scaleio_cache) unless Dir.exists? scaleio_cache
      file_path = File.join(scaleio_cache, "#{@opts[:server]}.json")
      File.write(file_path, results) unless results.empty?
    end
  end
end
