/**
 * VMRest-Commander
 * Copyright (C) 2026 Xianglong He
 * 
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 * 
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 * 
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */
let appConfig = null;
let currentHostsData = [];
let showHidden = false;
let pendingAction = null; // { ip, id, operation, vmName }
let autoScanInterval = null;

const DOM = {
    scanBtn: document.getElementById('scan-btn'),
    batchStartBtn: document.getElementById('batch-start-btn'),
    toggleHiddenBtn: document.getElementById('toggle-hidden-btn'),
    loading: document.getElementById('loading'),
    resultsContainer: document.getElementById('results-container'),
    modal: document.getElementById('confirmation-modal'),
    modalText: document.getElementById('modal-text'),
    modalCancelBtn: document.getElementById('modal-cancel-btn'),
    modalConfirmBtn: document.getElementById('modal-confirm-btn'),
    errorMessage: document.getElementById('error-message'),
    autoScanCheckbox: document.getElementById('auto-scan-checkbox')
};

async function fetchConfig() {
    try {
        const res = await fetch('/api/config');
        if (res.ok) {
            appConfig = await res.json();
            // Automatically scan when page loads
            scanNetwork();
        }
    } catch (e) {
        console.error('Failed to fetch config', e);
    }
}

async function updateConfig(updates) {
    try {
        await fetch('/api/config', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(updates)
        });
        await fetchConfig();
        renderHosts();
    } catch (e) {
        console.error('Failed to update config', e);
    }
}

async function scanNetwork(isBackground = false) {
    if (!isBackground) {
        DOM.loading.classList.remove('hidden');
        DOM.resultsContainer.innerHTML = '';
    }
    
    DOM.errorMessage.classList.add('hidden');

    try {
        const res = await fetch('/api/scan');
        if (!res.ok) throw new Error('Scan failed');
        currentHostsData = await res.json();
        renderHosts();
    } catch (e) {
        if (!isBackground) {
            DOM.errorMessage.textContent = 'Failed to scan the network. Check if server is running.';
            DOM.errorMessage.classList.remove('hidden');
        }
    } finally {
        if (!isBackground) {
            DOM.loading.classList.add('hidden');
        }
    }
}

function isHidden(vmId) {
    return appConfig && appConfig.hiddenVMs && appConfig.hiddenVMs.includes(vmId);
}

function toggleHiddenVM(vmId) {
    if (!appConfig) return;
    let hiddenVMs = [...(appConfig.hiddenVMs || [])];
    if (hiddenVMs.includes(vmId)) {
        hiddenVMs = hiddenVMs.filter(id => id !== vmId);
    } else {
        hiddenVMs.push(vmId);
    }
    updateConfig({ hiddenVMs });
}

function renderHosts() {
    DOM.resultsContainer.innerHTML = '';

    if (!currentHostsData || currentHostsData.length === 0) {
        DOM.resultsContainer.innerHTML = '<p style="text-align:center; color:var(--text-secondary)">No hosts found. Try scanning.</p>';
        return;
    }

    currentHostsData.forEach(host => {
        if (host.status !== 'online' || !host.vms || host.vms.length === 0) return;

        const section = document.createElement('div');
        section.className = 'host-section';

        const header = document.createElement('div');
        header.className = 'host-header';
        header.innerHTML = `
            <h2>Host: ${host.ip}</h2>
            <span class="status-badge online">Online</span>
        `;
        section.appendChild(header);

        const grid = document.createElement('div');
        grid.className = 'vm-grid';

        // Helper to extract VM name from path (parent directory)
        const getVmName = (vm) => {
            if (!vm.path) return vm.id;
            const parts = vm.path.split(/[/\\]/);
            if (parts.length >= 2 && parts[parts.length - 1].toLowerCase().endsWith('.vmx')) {
                return parts[parts.length - 2];
            }
            return vm.id;
        };

        host.vms.sort((a, b) => {
            const nameA = getVmName(a);
            const nameB = getVmName(b);
            return nameA.localeCompare(nameB, undefined, { sensitivity: 'base' });
        });

        let visibleCount = 0;

        host.vms.forEach(vm => {
            const hidden = isHidden(vm.id);
            if (hidden && !showHidden) return; // Skip if hidden and not showing hidden

            visibleCount++;
            
            const card = document.createElement('div');
            card.className = `vm-card glass ${hidden ? 'hidden-item' : ''}`;
            
            // Determine power status class
            const state = vm.power_state || 'unknown';
            let dotClass = 'suspended';
            if (state === 'poweredOn') dotClass = 'on';
            if (state === 'poweredOff') dotClass = 'off';

            // VM Name from parent directory
            const vmName = getVmName(vm);

            let powerActions = '';
            if (state === 'poweredOff') {
                powerActions = `<button class="btn primary small" onclick="promptAction('${host.ip}', '${vm.id}', 'on', '${vmName}')">Power On</button>`;
            } else if (state === 'suspended') {
                powerActions = `<button class="btn primary small" onclick="promptAction('${host.ip}', '${vm.id}', 'on', '${vmName}')">Resume</button>`;
            } else if (state === 'paused') {
                powerActions = `<button class="btn primary small" onclick="promptAction('${host.ip}', '${vm.id}', 'unpause', '${vmName}')">Unpause</button>`;
            } else {
                powerActions = `
                    <button class="btn danger small" onclick="promptAction('${host.ip}', '${vm.id}', 'off', '${vmName}')" title="Power Off (Hard)">Off</button>
                    <button class="btn secondary small" onclick="promptAction('${host.ip}', '${vm.id}', 'shutdown', '${vmName}')" title="Shutdown (Soft)">Shut</button>
                    <button class="btn secondary small" onclick="promptAction('${host.ip}', '${vm.id}', 'suspend', '${vmName}')">Suspend</button>
                    <button class="btn secondary small" onclick="promptAction('${host.ip}', '${vm.id}', 'pause', '${vmName}')">Pause</button>
                `;
            }

            card.innerHTML = `
                <div class="vm-header">
                    <div>
                        <div class="vm-title">${vmName}</div>
                        <div class="vm-id">${vm.id}</div>
                    </div>
                </div>
                <div class="vm-status">
                    <div class="status-dot ${dotClass}"></div>
                    <span>${state}</span>
                </div>
                <div class="vm-actions">
                    <div class="action-buttons-group">
                        ${powerActions}
                    </div>
                    <button class="btn secondary small" onclick="toggleHiddenVM('${vm.id}')">${hidden ? 'Unhide' : 'Hide'}</button>
                </div>
            `;
            grid.appendChild(card);
        });

        if (visibleCount > 0) {
            section.appendChild(grid);
            DOM.resultsContainer.appendChild(section);
        }
    });
}

// Modal handling
window.promptAction = function(ip, id, operation, vmName) {
    pendingAction = { ip, id, operation, vmName };
    if (operation === 'on') {
        confirmAction();
        return;
    }
    DOM.modalText.innerHTML = `Are you sure you want to <strong>power ${operation}</strong> the VM <strong>${vmName}</strong> on host ${ip}?`;
    DOM.modal.classList.remove('hidden');
}

function closeModal() {
    pendingAction = null;
    DOM.modal.classList.add('hidden');
}

async function confirmAction() {
    if (!pendingAction) return;
    
    const { ip, id, operation } = pendingAction;
    closeModal();
    
    // Optimistic UI update to make it feel fast
    const host = currentHostsData.find(h => h.ip === ip);
    if (host) {
        const vm = host.vms.find(v => v.id === id);
        if (vm) {
            if (operation === 'on') vm.power_state = 'poweringOn...';
            else if (operation === 'unpause') vm.power_state = 'resuming...';
            else if (operation === 'off' || operation === 'shutdown') vm.power_state = 'poweringOff...';
            else if (operation === 'suspend') vm.power_state = 'suspending...';
            else if (operation === 'pause') vm.power_state = 'pausing...';
        }
    }
    renderHosts();
    
    try {
        const res = await fetch('/api/power', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ ip, id, operation })
        });
        
        if (res.ok) {
            // Trigger a background rescan to ensure states are completely in sync
            scanNetwork(true);
        } else {
            const data = await res.json();
            const errorMsg = data.details ? (typeof data.details === 'object' ? JSON.stringify(data.details) : data.details) : data.error;
            alert(`Failed to change power state: ${errorMsg}`);
            scanNetwork(true);
        }
    } catch (e) {
        console.error(e);
        alert('An error occurred while changing power state.');
        scanNetwork(true);
    }
}

// Event Listeners
DOM.scanBtn.addEventListener('click', () => scanNetwork(false));
DOM.batchStartBtn.addEventListener('click', () => {
    if (confirm('Are you sure you want to start VMs in sequence according to the config?')) {
        batchPowerOn();
    }
});
DOM.toggleHiddenBtn.addEventListener('click', () => {
    showHidden = !showHidden;
    DOM.toggleHiddenBtn.textContent = showHidden ? 'Hide Hidden VMs' : 'Show Hidden VMs';
    renderHosts();
});
DOM.autoScanCheckbox.addEventListener('change', (e) => {
    if (e.target.checked) {
        autoScanInterval = setInterval(() => scanNetwork(true), 30000); // 30s
    } else {
        clearInterval(autoScanInterval);
        autoScanInterval = null;
    }
});
DOM.modalCancelBtn.addEventListener('click', closeModal);
DOM.modalConfirmBtn.addEventListener('click', confirmAction);

async function batchPowerOn() {
    if (!appConfig || !appConfig.bootSequence) {
        alert("Boot sequence not configured in config.json.");
        return;
    }
    
    DOM.loading.classList.remove('hidden');
    DOM.errorMessage.classList.add('hidden');
    const loadingText = DOM.loading.querySelector('p');
    loadingText.textContent = 'Starting VMs in sequence...';

    const getVmName = (vm) => {
        if (!vm.path) return vm.id;
        const parts = vm.path.split(/[/\\]/);
        if (parts.length >= 2 && parts[parts.length - 1].toLowerCase().endsWith('.vmx')) {
            return parts[parts.length - 2];
        }
        return vm.id;
    };

    const sequence = appConfig.bootSequence;
    
    try {
        for (const pattern of sequence) {
            const regex = new RegExp('^' + pattern.replace(/\*/g, '.*') + '$', 'i');
            
            const vmsToStart = [];
            currentHostsData.forEach(host => {
                if (host.status !== 'online' || !host.vms) return;
                host.vms.forEach(vm => {
                    const vmName = getVmName(vm);
                    if (regex.test(vmName) && (vm.power_state === 'poweredOff' || vm.power_state === 'suspended' || vm.power_state === 'unknown')) {
                        vmsToStart.push({ ip: host.ip, id: vm.id, name: vmName });
                    }
                });
            });

            if (vmsToStart.length > 0) {
                console.log(`Starting group ${pattern}:`, vmsToStart.map(v => v.name));
                loadingText.textContent = `Starting ${pattern} (${vmsToStart.length} VMs)...`;
                
                // Optimistically update UI state
                vmsToStart.forEach(vmInfo => {
                    const host = currentHostsData.find(h => h.ip === vmInfo.ip);
                    if (host) {
                        const vm = host.vms.find(v => v.id === vmInfo.id);
                        if (vm) vm.power_state = 'poweringOn...';
                    }
                });
                renderHosts();
                
                const promises = vmsToStart.map(vmInfo => {
                    return fetch('/api/power', {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({ ip: vmInfo.ip, id: vmInfo.id, operation: 'on' })
                    });
                });
                
                await Promise.allSettled(promises);
                
                // Trigger a background scan to reflect actual states
                scanNetwork(true);
                
                // Wait 15 seconds for this group to start booting before next sequence
                await new Promise(r => setTimeout(r, 15000));
            }
        }
        alert("Batch power on completed.");
    } catch (e) {
        console.error(e);
        alert('An error occurred during batch power on.');
    } finally {
        loadingText.textContent = 'Scanning network, please wait...';
        DOM.loading.classList.add('hidden');
        scanNetwork(true);
    }
}

// Init
fetchConfig();
if (DOM.autoScanCheckbox.checked) {
    autoScanInterval = setInterval(() => scanNetwork(true), 30000);
}
