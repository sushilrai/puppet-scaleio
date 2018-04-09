#!/opt/puppet/bin/ruby

require "trollop"
require "json"
require "timeout"
require "pathname"

puppet_dir = File.join(Pathname.new(__FILE__).parent.parent,'lib','puppet')
require "%s/scaleio/transport" % [puppet_dir]

@opts = Trollop::options do
  opt :server, "ScaleIO gateway", :type => :string, :required => true
  opt :port, "ScaleIO gateway port", :default => 443
  opt :username, "ScaleIO gateway username", :type => :string, :required => true
  opt :password, "ScaleIO gateway password", :type => :string, :default => ENV["PASSWORD"]
  opt :timeout, "ScaleIO gateway connection timeout", :type => :integer, :default => 300, :required => false
  opt :credential_id, "dummy value for ASM, not used"
  opt :output, "Location of the file where facts file needs to be created", :type => :string, :required => false
end

def collect_scaleio_facts
  facts = {:protection_domain_list => []}
  facts[:certname] = "scaleio-%s" % [@opts[:server]]
  facts[:name] = "scaleio-%s" % [@opts[:server]]
  facts[:update_time] = Time.now
  facts[:device_type] = "script"

  # ScaleIO MDM is not configured
  # Need to return basic information
  if scaleio_cookie == "NO MDM"
    facts = {
      :general => { "name" => facts[:certname] },
      :statistics => {},
      :sdc_list => [],
      :protection_domain_list => [],
      :fault_sets => []
    }

    return facts
  end

  scaleio_system = scaleio_systems[0]

  facts[:general] = scaleio_system
  facts[:general]["name"] ||= facts[:certname]

  facts[:statistics] = scaleio_system_statistics(scaleio_system)
  facts[:sdc_list] = scaleio_sdc(scaleio_system)
  sdsList = scaleio_sds(scaleio_system)
  volumes = scaleio_volumes(scaleio_system)
  protection_domains(scaleio_system).each do |protection_domain|
    pd = {:general => protection_domain,
          :statistics => scaleio_protection_domain_statistics(protection_domain),
          :storage_pool_list => storage_pools(scaleio_system, protection_domain)}
    pd[:sds_list] = sdsList.select {|sds| sds[:protectionDomainId] == protection_domain[:id]}
    pd[:storage_pool_list].each do |storage_pool|
      storage_pool[:statistics] = scaleio_storage_pool_statistics(storage_pool)
      storage_pool[:disk_list] = disks(storage_pool)
      storage_pool[:volume_list] = volumes.select {|volume| volume[:storagePoolId] == storage_pool[:id]}
    end
    facts[:protection_domain_list] << pd
  end
  facts[:fault_sets] = scaleio_faultsets(scaleio_system)
  facts
end

def scaleio_systems
  url = transport.get_url("/api/types/System/instances")
  transport.post_request(url, {}, "get") || []
end

def scaleio_system_statistics(scaleio_system)
  end_point = "/api/instances/System::%s/relationships/Statistics" % [scaleio_system["id"]]
  url = transport.get_url(end_point)
  transport.post_request(url, {}, "get") || []
end

def scaleio_sds(scaleio_system)
  sds_url = "/api/types/Sds/instances?systemId=%s" % [scaleio_system["id"]]
  url = transport.get_url(sds_url)
  transport.post_request(url, {}, "get") || []
end

def scaleio_sdc(scaleio_system)
  sdc_url = "/api/types/Sdc/instances?systemId=%s" % [scaleio_system["id"]]
  url = transport.get_url(sdc_url)
  transport.post_request(url, {}, "get") || []
end

def protection_domains(scaleio_system)
  pd_url = "/api/types/ProtectionDomain/instances?systemId=%s" % [scaleio_system["id"]]
  url = transport.get_url(pd_url)
  transport.post_request(url, {}, "get") || []
end

def scaleio_protection_domain_statistics(protection_domain)
  end_point = "/api/instances/ProtectionDomain::%s/relationships/Statistics" % [protection_domain["id"]]
  url = transport.get_url(end_point)
  transport.post_request(url, {}, "get") || []
end

def storage_pools(scaleio_system, protection_domain)
  sp_url = "/api/types/StoragePool/instances?systemId=%s&protectiondomainId=%s" % [scaleio_system["id"], protection_domain["id"]]
  url = transport.get_url(sp_url)
  transport.post_request(url, {}, "get") || []
end

def scaleio_storage_pool_statistics(storage_pool)
  end_point = "/api/instances/StoragePool::%s/relationships/Statistics" % [storage_pool["id"]]
  url = transport.get_url(end_point)
  transport.post_request(url, {}, "get") || []
end

def disks(storage_pool)
  sp_url = "/api/types/Device/instances?storagepoolId=%s" % [storage_pool["id"]]
  url = transport.get_url(sp_url)
  transport.post_request(url, {}, "get") || []
end

def scaleio_volumes(scaleio_system)
  volume_url = "/api/types/Volume/instances?systemId=%s" % [scaleio_system["id"]]
  url = transport.get_url(volume_url)
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
      file_path = File.join(scaleio_cache, "#{opts[:server]}.json")
      File.write(file_path, results) unless results.empty?
    end
  end
end
