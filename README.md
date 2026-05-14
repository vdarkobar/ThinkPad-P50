# ThinkPad-P50
Lenovo  ThinkPad P50 Workstation setup and maintenance




#### *Setup Fedora 44 with Btrfs Snapshot and Rollback Support <a href="https://github.com/vdarkobar/ThinkPad-P50/blob/main/Fedora-44-Btrfs-snapshot-rollback.md"> * </a>*:

#### *A Fedora-focused installer for initializing and enabling the Validity/Synaptics VFS7500 fingerprint reader <a href="https://github.com/vdarkobar/thinkpad-vfs0090-fingerprint"> * </a>*:


<details>
  <summary>Post-install script Debian 13</summary>
  <p>Run on a clean Debian installation:</p>
  <pre><code>tmp="$(mktemp)" &amp;&amp; curl -fsSL https://raw.githubusercontent.com/vdarkobar/ThinkPad-P50/main/post-install-deb.sh -o "$tmp" &amp;&amp; sudo bash "$tmp"; rm -f "$tmp"</code></pre>
</details>
  
<details>
  <summary>Fingerprint setup Debian 13</summary>
  <p>Initializing and enabling the Validity/Synaptics VFS7500 fingerprint reader:</p>
  <pre><code>tmp="$(mktemp)" &amp;&amp; curl -fsSL https://raw.githubusercontent.com/vdarkobar/ThinkPad-P50/main/fingerprint-deb.sh -o "$tmp" &amp;&amp; sudo bash "$tmp"; rm -f "$tmp"</code></pre>
</details>
