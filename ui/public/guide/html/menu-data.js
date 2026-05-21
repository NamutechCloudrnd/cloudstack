export const menuData = {
  menu: [
    {
      id: '01_compute',
      label: 'Compute',
      items: [
        {
          id: '01_instances',
          label: 'Instances',
          path: '01_compute/01_instances/instances',
        },
        {
          id: '02_instances_snapshots',
          label: 'Instances Snapshots',
          path: '01_compute/02_instances_snapshots/instances_snapshots',
        },
        {
          id: '03_kubernetes',
          label: 'Kubernetes',
          path: '01_compute/03_kubernetes/kubernetes',
        },
        {
          id: '04_autoscaling_groups',
          label: 'Autoscaling Groups',
          path: '01_compute/04_autoscaling_groups/autoscaling_groups',
        },
        {
          id: '05_instance_groups',
          label: 'Instance Groups',
          path: '01_compute/05_instance_groups/instance_groups',
        },
        {
          id: '06_ssh_key_pairs',
          label: 'SSH Key Pairs',
          path: '01_compute/06_ssh_key_pairs/ssh_key_pairs',
        },
        {
          id: '07_user_data_library',
          label: 'User Data Library',
          path: '01_compute/07_user_data_library/user_data_library',
        },
        {
          id: '08_cni_configuration',
          label: 'CNI Configuration',
          path: '01_compute/08_cni_configuration/cni_configuration',
        },
        {
          id: '09_affinity_groups',
          label: 'Affinity Groups',
          path: '01_compute/09_affinity_groups/affinity_groups',
        },
      ],
    },
    {
      id: '02_storage',
      label: 'Storage',
      items: [
        {
          id: '01_volumes',
          label: 'Volumes',
          path: '02_storage/01_volumes/volumes',
        },
        {
          id: '02_volume_snapshots',
          label: 'Volume Snapshots',
          path: '02_storage/02_volume_snapshots/volume_snapshots',
        },
        {
          id: '03_snapshot_policies',
          label: 'Snapshot Policies',
          path: '02_storage/03_snapshot_policies/snapshot_policies',
        },
        {
          id: '04_backups',
          label: 'Backups',
          path: '02_storage/04_backups/backups',
        },
        {
          id: '05_backup_schedules',
          label: 'Backup Schedules',
          path: '02_storage/05_backup_schedules/backup_schedules',
        },
        {
          id: '06_buckets',
          label: 'Buckets',
          path: '02_storage/06_buckets/buckets',
        },
        {
          id: '07_shared_filesystems',
          label: 'Shared Filesystems',
          path: '02_storage/07_shared_filesystems/shared_filesystems',
        },
      ],
    },
    {
      id: '03_network',
      label: 'Network',
      items: [
        {
          id: '01_guest_networks',
          label: 'Guest Networks',
          path: '03_network/01_guest_networks/guest_networks',
        },
        {
          id: '02_vpc',
          label: 'VPC',
          path: '03_network/02_vpc/vpc',
        },
        {
          id: '03_security_group',
          label: 'Security Group',
          path: '03_network/03_security_group/security_group',
        },
        {
          id: '04_vnf_appliances',
          label: 'VNF Appliances',
          path: '03_network/04_vnf_appliances/vnf_appliances',
        },
        {
          id: '05_public_ip_addresses',
          label: 'Public IP Addresses',
          path: '03_network/05_public_ip_addresses/public_ip_addresses',
        },
        {
          id: '06_as_numbers',
          label: 'AS Numbers',
          path: '03_network/06_as_numbers/as_numbers',
        },
        {
          id: '07_site_to_site_vpn',
          label: 'Site to Site VPN',
          path: '03_network/07_site_to_site_vpn/site_to_site_vpn',
        },
        {
          id: '08_vpn_connections',
          label: 'VPN Connections',
          path: '03_network/08_vpn_connections/vpn_connections',
        },
        {
          id: '09_network_acls',
          label: 'Network ACLs',
          path: '03_network/09_network_acls/network_acls',
        },
        {
          id: '10_vpn_users',
          label: 'VPN Users',
          path: '03_network/10_vpn_users/vpn_users',
        },
        {
          id: '11_vpn_customer_gateway',
          label: 'VPN Customer Gateway',
          path: '03_network/11_vpn_customer_gateway/vpn_customer_gateway',
        },
        {
          id: '12_guest_vlan',
          label: 'Guest VLAN',
          path: '03_network/12_guest_vlan/guest_vlan',
        },
        {
          id: '13_ipv4_subnets',
          label: 'IPv4 Subnets',
          path: '03_network/13_ipv4_subnets/ipv4_subnets',
        },
      ],
    },
    {
      id: '04_images',
      label: 'Images',
      items: [
        {
          id: '01_templates',
          label: 'Templates',
          path: '04_images/01_templates/templates',
        },
        {
          id: '02_isos',
          label: 'ISOs',
          path: '04_images/02_isos/isos',
        },
        {
          id: '03_kubernetes_isos',
          label: 'Kubernetes ISOs',
          path: '04_images/03_kubernetes_isos/kubernetes_isos',
        },
      ],
    },
    {
      id: '05_events',
      label: 'Events',
      items: [
        {
          id: '01_events',
          label: 'Events',
          path: '05_events/01_events/events',
        },
      ],
    },
    {
      id: '06_projects',
      label: 'Projects',
      items: [
        {
          id: '01_projects',
          label: 'Projects',
          path: '06_projects/01_projects/projects',
        },
      ],
    },
    {
      id: '07_roles',
      label: 'Roles',
      items: [
        {
          id: '01_roles',
          label: 'Roles',
          path: '07_roles/01_roles/roles',
        },
      ],
    },
    {
      id: '08_accounts',
      label: 'Accounts',
      items: [
        {
          id: '01_accounts',
          label: 'Accounts',
          path: '08_accounts/01_accounts/accounts',
        },
      ],
    },
    {
      id: '09_domains',
      label: 'Domains',
      items: [
        {
          id: '01_domains',
          label: 'Domains',
          path: '09_domains/01_domains/domains',
        },
      ],
    },
    {
      id: '10_infrastructure',
      label: 'Infrastructure',
      items: [
        {
          id: '01_summary',
          label: 'Summary',
          path: '10_infrastructure/01_summary/summary',
        },
        {
          id: '02_zones',
          label: 'Zones',
          path: '10_infrastructure/02_zones/zones',
        },
        {
          id: '03_pods',
          label: 'Pods',
          path: '10_infrastructure/03_pods/pods',
        },
        {
          id: '04_clusters',
          label: 'Clusters',
          path: '10_infrastructure/04_clusters/clusters',
        },
        {
          id: '05_hosts',
          label: 'Hosts',
          path: '10_infrastructure/05_hosts/hosts',
        },
        {
          id: '06_primary_storage',
          label: 'Primary Storage',
          path: '10_infrastructure/06_primary_storage/primary_storage',
        },
        {
          id: '07_secondary_storage',
          label: 'Secondary Storage',
          path: '10_infrastructure/07_secondary_storage/secondary_storage',
        },
        {
          id: '08_backup_repository',
          label: 'Backup Repository',
          path: '10_infrastructure/08_backup_repository/backup_repository',
        },
        {
          id: '09_object_storage',
          label: 'Object Storage',
          path: '10_infrastructure/09_object_storage/object_storage',
        },
        {
          id: '10_system_vms',
          label: 'System VMs',
          path: '10_infrastructure/10_system_vms/system_vms',
        },
        {
          id: '11_virtual_routers',
          label: 'Virtual Routers',
          path: '10_infrastructure/11_virtual_routers/virtual_routers',
        },
        {
          id: '12_internal_lb',
          label: 'Internal LB',
          path: '10_infrastructure/12_internal_lb/internal_lb',
        },
        {
          id: '13_management_servers',
          label: 'Management Servers',
          path: '10_infrastructure/13_management_servers/management_servers',
        },
        {
          id: '14_cpu_sockets',
          label: 'CPU Sockets',
          path: '10_infrastructure/14_cpu_sockets/cpu_sockets',
        },
        {
          id: '15_dbusage_server',
          label: 'DB Usage Server',
          path: '10_infrastructure/15_dbusage_server/dbusage_server',
        },
        {
          id: '16_alerts',
          label: 'Alerts',
          path: '10_infrastructure/16_alerts/alerts',
        },
      ],
    },
    {
      id: '11_offerings',
      label: 'Offerings',
      items: [
        {
          id: '01_compute_offerings',
          label: 'Compute Offerings',
          path: '11_offerings/01_compute_offerings/compute_offerings',
        },
        {
          id: '02_system_offerings',
          label: 'System Offerings',
          path: '11_offerings/02_system_offerings/system_offerings',
        },
        {
          id: '03_disk_offerings',
          label: 'Disk Offerings',
          path: '11_offerings/03_disk_offerings/disk_offerings',
        },
        {
          id: '04_backup_offerings',
          label: 'Backup Offerings',
          path: '11_offerings/04_backup_offerings/backup_offerings',
        },
        {
          id: '05_network_offerings',
          label: 'Network Offerings',
          path: '11_offerings/05_network_offerings/network_offerings',
        },
        {
          id: '06_vpc_offerings',
          label: 'VPC Offerings',
          path: '11_offerings/06_vpc_offerings/vpc_offerings',
        },
      ],
    },
    {
      id: '12_configuration',
      label: 'Configuration',
      items: [
        {
          id: '01_global_settings',
          label: 'Global Settings',
          path: '12_configuration/01_global_settings/global_settings',
        },
        {
          id: '02_ldap_configuration',
          label: 'LDAP Configuration',
          path: '12_configuration/02_ldap_configuration/ldap_configuration',
        },
        {
          id: '03_oauth_configuration',
          label: 'OAuth Configuration',
          path: '12_configuration/03_oauth_configuration/oauth_configuration',
        },
        {
          id: '04_hypervisor_capabilities',
          label: 'Hypervisor Capabilities',
          path: '12_configuration/04_hypervisor_capabilities/hypervisor_capabilities',
        },
        {
          id: '05_guest_os_categories',
          label: 'Guest OS Categories',
          path: '12_configuration/05_guest_os_categories/guest_os_categories',
        },
        {
          id: '06_guest_os',
          label: 'Guest OS',
          path: '12_configuration/06_guest_os/guest_os',
        },
        {
          id: '07_guest_os_mappings',
          label: 'Guest OS Mappings',
          path: '12_configuration/07_guest_os_mappings/guest_os_mappings',
        },
        {
          id: '08_gpu_card_types',
          label: 'GPU Card Types',
          path: '12_configuration/08_gpu_card_types/gpu_card_types',
        },
      ],
    },
    {
      id: '13_extensions',
      label: 'Extensions',
      items: [
        {
          id: '01_extensions',
          label: 'Extensions',
          path: '13_extensions/01_extensions/extensions',
        },
      ],
    },
    {
      id: '14_tools',
      label: 'Tools',
      items: [
        {
          id: '01_comments',
          label: 'Comments',
          path: '14_tools/01_comments/comments',
        },
        {
          id: '02_usage',
          label: 'Usage',
          path: '14_tools/02_usage/usage',
        },
        {
          id: '03_import_export_instances',
          label: 'Import Export Instances',
          path: '14_tools/03_import_export_instances/import_export_instances',
        },
        {
          id: '04_import_data_volumes',
          label: 'Import Data Volumes',
          path: '14_tools/04_import_data_volumes/import_data_volumes',
        },
        {
          id: '05_webhooks',
          label: 'Webhooks',
          path: '14_tools/05_webhooks/webhooks',
        },
      ],
    },
  ],
}
