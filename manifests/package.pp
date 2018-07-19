define scaleio::package (
  $ensure = undef,
  $pkg_ftp = undef,
  $pkg_path = undef,
  $scaleio_password = undef,
  $scaleio_yum_repo = undef
  )
{
  $package = $::osfamily ? {
    'RedHat' => $title ? {
      'gateway' => 'EMC-ScaleIO-gateway',
      'gui'     => 'EMC-ScaleIO-gui',
      'mdm'     => 'EMC-ScaleIO-mdm',
      'sdc'     => 'EMC-ScaleIO-sdc',
      'sds'     => 'EMC-ScaleIO-sds',
      'xcache'  => 'EMC-ScaleIO-xcache',
      'lia'     => 'EMC-ScaleIO-lia'
    },
    'Debian' => $title ? {
      'gateway' => 'emc-scaleio-gateway',
      'gui'     => 'EMC_ScaleIO_GUI',
      'mdm'     => 'emc-scaleio-mdm',
      'sdc'     => 'emc-scaleio-sdc',
      'sds'     => 'emc-scaleio-sds',
      'xcache'  => 'emc-scaleio-xcache',
      'lia'     => 'emc-scaleio-lia',
    },
    'Suse' => $title ? {
      'gateway' => 'EMC-ScaleIO-gateway',
      'gui'     => 'EMC-ScaleIO-gui',
      'mdm'     => 'EMC-ScaleIO-mdm',
      'sdc'     => 'EMC-ScaleIO-sdc',
      'sds'     => 'EMC-ScaleIO-sds',
      'xcache'  => 'EMC-ScaleIO-xcache',
      'lia'     => 'EMC-ScaleIO-lia'
    },
  }

  $rel = $::operatingsystemmajrelease ? {
    '' => $::operatingsystemrelease,
    default => $::operatingsystemmajrelease
  }
  $version = $::osfamily ? {
    'RedHat' => "RHEL${rel}",
    'Debian' => "Ubuntu${rel}",
    'Suse' => "SUSE${rel}",
  }
  $provider = $::osfamily ? {
    'RedHat' => 'rpm',
    'Debian' => 'dpkg',
    'Suse' => 'rpm',
  }

  $pkg_ext = $::osfamily ? {
    'RedHat' => 'rpm',
    'Debian' => 'deb',
    'Suse' => 'rpm',
  }

  if $ensure == 'absent' {
    package { $package:
      ensure => absent,
    }
  }
  elsif $pkg_ftp and $pkg_ftp != '' {
    $ftp_url = "${pkg_ftp}/${version}"

    file { "ensure get_package.sh for ${title}":
      ensure => present,
      path   => "/root/get_package_${title}.sh",
      source => 'puppet:///modules/scaleio/get_package.sh',
      mode   => '0700',
      owner  => 'root',
      group  => 'root',
    } ->
    exec { "get_package ${title}":
      command => "/root/get_package_${title}.sh ${ftp_url} ${title}",
      path    => '/bin:/usr/bin',
    } ->
    package { $package:
      ensure   => $ensure,
      source   => "/tmp/${title}/${title}.${pkg_ext}",
      provider => $provider,
    }
  }
  elsif $pkg_path and $pkg_path != '' {
    if $package == 'lia' {
      exec {"$provider ${pkg_path}/$version/${package}*.${pkg_ext}":
        environment => [ "TOKEN=${scaleio::password}" ],
        tag         => 'scaleio-install',
        unless      => "rpm -q 'EMC-ScaleIO-lia'",
        path        => '/bin:/usr/bin',
      }
    } else {
      package {$package:
        provider => $provider,
        source => "${pkg_path}/$version/${package}*.${pkg_ext}",
      }
    }
  }
  else {
    if $package == 'lia' {
      exec {"yum -y install $package":
        command => "TOKEN=${scaleio_password} yum -y install $package",
        unless      => "rpm -q 'EMC-ScaleIO-lia'",
        path        => '/bin:/usr/bin',
      }
    } else {
      package {$package:}
    }
  }
}
