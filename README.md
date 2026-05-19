# ThinkPad-P50
*Lenovo  ThinkPad P50 Workstation setup and maintenance, Debian 13 Trixie*
  
  
<details>
  <summary>Post-install</summary>
  <p>Run on a clean Debian 13 installation:</p>
  <pre><code>tmp="$(mktemp)" && wget -qO "$tmp" "https://raw.githubusercontent.com/vdarkobar/ThinkPad-P50/main/post-install-deb.sh" && bash "$tmp"; rc=$?; rm -f "$tmp"; (exit "$rc")</code></pre>
</details>
  
<details>
  <summary>Storage helper</summary>
  <p>Prepare storage on ThinkPad P50 (2 x nvme drives, 1 x ssd):</p>
  <pre><code>tmp="$(mktemp)" && wget -qO "$tmp" "https://raw.githubusercontent.com/vdarkobar/ThinkPad-P50/main/storage-helper.sh" && bash "$tmp"; rc=$?; rm -f "$tmp"; (exit "$rc")</code></pre>
</details>
  
<details>
  <summary>Fingerprint setup</summary>
  <p>Initializing and enabling the Validity/Synaptics VFS7500 fingerprint reader:</p>
  <pre><code>tmp="$(mktemp)" &amp;&amp; curl -fsSL https://raw.githubusercontent.com/vdarkobar/ThinkPad-P50/main/fingerprint-deb.sh -o "$tmp" &amp;&amp; sudo bash "$tmp"; rm -f "$tmp"</code></pre>
</details>
  
<details>
  <summary>Nvidia Driver install</summary>
  <p>Nvidia Driver installation, works on Secure boot:</p>
  <pre><code>tmp="$(mktemp)" &amp;&amp; curl -fsSL https://raw.githubusercontent.com/vdarkobar/ThinkPad-P50/refs/heads/main/nvidia-driver-install.sh -o "$tmp" &amp;&amp; bash "$tmp"; rm -f "$tmp"</code></pre>
</details>
  
  
  
<p align="center">
  <b>Download:</b><br>
<a href="https://docs.fedoraproject.org/en-US/quick-docs/creating-windows-virtual-machines-using-virtio-drivers/index.html#virtio-win-direct-downloads">VirtIO drivers</a> >
<a href="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso">Stable</a> |
<a href="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso">Latest</a>
  <br><br>
</p>
  
### Windows Autologon <a href="https://download.sysinternals.com/files/AutoLogon.zip"> * </a> | <a href="https://github.com/vdarkobar/ThinkPad-P50/blob/main/AL.zip"> * </a>




