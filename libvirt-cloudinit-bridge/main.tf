locals {
  cidr_splitted      = split("/", var.cidr)
  cidr_subnet        = local.cidr_splitted[0]
  cidr_prefix        = local.cidr_splitted[1]
  nameservers_string = "[\"${join("\", \"", var.nameservers)}\"]"

  # Auto-calculate mac address from IP
  ips_parts = [for vm in var.vms : split(".", vm.ip)]
  mac_addrs = [
    for ip_parts in local.ips_parts : format(
      "52:54:00:%02X:%02X:%02X",
      tonumber(ip_parts[1]),
      tonumber(ip_parts[2]),
      tonumber(ip_parts[3])
    )
  ]
}

resource "libvirt_cloudinit_disk" "commoninit" {
  count = length(var.vms)
  name  = "commoninit_${var.vms[count.index].name}.iso"
  user_data = templatefile(var.vms[count.index].cloudinit_file, {
    hostname = var.vms[count.index].name
  })
  network_config = templatefile("${path.module}/network_config.cfg", {
    ip          = var.vms[count.index].ip
    cidr_prefix = local.cidr_prefix
    gateway     = var.gateway
    nameservers = local.nameservers_string
  })
  pool = var.pool
}

locals {
  volume_list      = { for vm in var.vms : "${vm.name}" => flatten([for volume in vm.volumes : volume]) }
  volume_name_list = [for vm, volumes in local.volume_list : [for volume in volumes : { "name" : "${vm}_${volume.name}", "disk" : volume.disk }]]
  volumes          = flatten(local.volume_name_list)
  volumes_indexed  = { for index, volume in local.volumes : volume.name => index }
}

resource "libvirt_domain" "vm" {
  count   = length(var.vms)
  name    = var.vms[count.index].name
  vcpu    = var.vms[count.index].vcpu
  memory  = var.vms[count.index].memory
  machine = "q35"

  disk {
    volume_id = libvirt_volume.system[count.index].id
    scsi      = true
  }

  dynamic "disk" {
    for_each = local.volume_list[var.vms[count.index].name]
    content {
      volume_id = libvirt_volume.volume[lookup(local.volumes_indexed, "${var.vms[count.index].name}_${disk.value.name}")].id
      scsi      = true
    }
  }

  cloudinit = libvirt_cloudinit_disk.commoninit[count.index].id
  autostart = true

  network_interface {
    bridge    = var.bridge
    addresses = [var.vms[count.index].ip]
    mac       = local.mac_addrs[count.index]
  }

  #qemu_agent = true

  cpu {
    mode = "host-passthrough"
  }

  graphics {
    type        = "vnc"
    listen_type = "address"
  }

  # Makes the tty0 available via `virsh console`
  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  xml {
    xslt = file("${path.module}/patch.xsl")
  }
}

resource "libvirt_volume" "system" {
  count          = length(var.vms)
  name           = "${var.vms[count.index].name}_system.qcow2"
  pool           = var.pool
  format         = "qcow2"
  base_volume_id = var.vm_base_image_uri
  size           = var.vms[count.index].disk
}

resource "libvirt_volume" "volume" {
  count  = length(local.volumes)
  name   = "${local.volumes[count.index].name}.qcow2"
  pool   = var.pool
  format = "qcow2"
  size   = local.volumes[count.index].disk
}
