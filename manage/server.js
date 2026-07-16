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
const express = require('express');
const fs = require('fs');
const path = require('path');
const axios = require('axios');
const cors = require('cors');

const app = express();
const PORT = 3001;

app.use(cors());
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

const CONFIG_SAMPLE_PATH = path.join(__dirname, 'config-sample.json');
const CONFIG_PATH = path.join(__dirname, 'config.json');

// Ensure config.json exists
if (!fs.existsSync(CONFIG_PATH)) {
    if (fs.existsSync(CONFIG_SAMPLE_PATH)) {
        fs.copyFileSync(CONFIG_SAMPLE_PATH, CONFIG_PATH);
        console.log('Created config.json from config-sample.json');
    } else {
        console.error('config-sample.json not found!');
        process.exit(1);
    }
}

// Helper to read config
function getConfig() {
    const data = fs.readFileSync(CONFIG_PATH, 'utf-8');
    return JSON.parse(data);
}

// Helper to write config
function writeConfig(config) {
    fs.writeFileSync(CONFIG_PATH, JSON.stringify(config, null, 2));
}

// Helper to convert IP to number
function ip2int(ip) {
    return ip.split('.').reduce((ipInt, octet) => (ipInt << 8) + parseInt(octet, 10), 0) >>> 0;
}

// Helper to convert number to IP
function int2ip(ipInt) {
    return (
        ((ipInt >>> 24) & 255) + '.' +
        ((ipInt >>> 16) & 255) + '.' +
        ((ipInt >>> 8) & 255) + '.' +
        (ipInt & 255)
    );
}

// API: Get config
app.get('/api/config', (req, res) => {
    try {
        const config = getConfig();
        // Hide password before sending to frontend
        const safeConfig = { ...config, password: '***' };
        res.json(safeConfig);
    } catch (e) {
        res.status(500).json({ error: 'Failed to read config' });
    }
});

// API: Update config (e.g., hiddenVMs)
app.post('/api/config', (req, res) => {
    try {
        const currentConfig = getConfig();
        const newConfig = { ...currentConfig, ...req.body };
        // Don't overwrite password with '***'
        if (req.body.password === '***') {
            newConfig.password = currentConfig.password;
        }
        writeConfig(newConfig);
        res.json({ success: true });
    } catch (e) {
        res.status(500).json({ error: 'Failed to write config' });
    }
});

// Axios instance factory for vmrest
function getVmrestClient(ip, username, password) {
    const client = axios.create({
        baseURL: `http://${ip}:55555/api`,
        timeout: 3000,
        auth: {
            username: username,
            password: password
        },
        headers: {
            'Content-Type': 'application/vnd.vmware.vmw.rest-v1+json',
            'Accept': 'application/vnd.vmware.vmw.rest-v1+json'
        }
    });

    client.interceptors.request.use(request => {
        console.log(`\x1b[36m[vmrest CALL]\x1b[0m ${request.method.toUpperCase()} ${request.baseURL}${request.url}`);
        if (request.data) {
            console.log(`\x1b[36m[vmrest DATA]\x1b[0m ${request.data}`);
        }
        return request;
    });

    client.interceptors.response.use(response => {
        console.log(`\x1b[32m[vmrest RESP]\x1b[0m ${response.status} OK - ${response.config.url}`);
        return response;
    }, error => {
        const url = error.config ? error.config.url : 'unknown url';
        console.log(`\x1b[91m[vmrest ERR]\x1b[0m ${error.message} - ${url}`);
        if (error.response && error.response.data) {
            const details = typeof error.response.data === 'object' ? JSON.stringify(error.response.data) : error.response.data;
            console.log(`\x1b[91m[vmrest ERR DETAILS]\x1b[0m ${details}`);
        }
        return Promise.reject(error);
    });

    return client;
}

// API: Scan IPs for VMs
app.get('/api/scan', async (req, res) => {
    try {
        const config = getConfig();
        const startInt = ip2int(config.startIp);
        const endInt = ip2int(config.endIp);
        
        if (startInt > endInt) {
            return res.status(400).json({ error: 'startIp must be <= endIp' });
        }

        const ips = [];
        for (let i = startInt; i <= endInt; i++) {
            ips.push(int2ip(i));
        }

        const scanPromises = ips.map(async (ip) => {
            const client = getVmrestClient(ip, config.username, config.password);
            try {
                // Fetch all VMs
                const vmsResponse = await client.get('/vms');
                const vms = vmsResponse.data;
                
                // For each VM, fetch its power state
                const vmsWithPower = await Promise.all(vms.map(async (vm) => {
                    try {
                        const powerResponse = await client.get(`/vms/${vm.id}/power`);
                        return { ...vm, power_state: powerResponse.data.power_state, host_ip: ip };
                    } catch (e) {
                        return { ...vm, power_state: 'unknown', host_ip: ip };
                    }
                }));

                return { ip: ip, status: 'online', vms: vmsWithPower };
            } catch (e) {
                // If it fails, assume no vmrest or unreachable
                return { ip: ip, status: 'offline', vms: [] };
            }
        });

        const results = await Promise.all(scanPromises);
        res.json(results);
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: 'Scan failed' });
    }
});

// API: Change Power State
app.post('/api/power', async (req, res) => {
    const { ip, id, operation } = req.body;
    if (!ip || !id || !operation) {
        return res.status(400).json({ error: 'Missing parameters' });
    }

    try {
        const config = getConfig();
        const client = getVmrestClient(ip, config.username, config.password);
        
        // vmrest expects the raw string without quotes for the body, but with the custom Content-Type
        const response = await client.put(`/vms/${id}/power`, operation, {
            headers: {
                'Content-Type': 'application/vnd.vmware.vmw.rest-v1+json'
            },
            timeout: 60000
        });
        res.json(response.data);
    } catch (e) {
        console.error(e.response ? e.response.data : e.message);
        res.status(500).json({ error: 'Failed to change power state', details: e.response ? e.response.data : e.message });
    }
});

app.listen(PORT, '127.0.0.1', () => {
    console.log(`Server running on http://127.0.0.1:${PORT}`);
});
