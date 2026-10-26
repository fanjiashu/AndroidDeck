const { contextBridge, ipcRenderer, webUtils } = require('electron');
contextBridge.exposeInMainWorld('deck', {
  call: (action, payload) => ipcRenderer.invoke('deck:call', action, payload),
  input: message => ipcRenderer.send('deck:input', message),
  filePath: file => webUtils.getPathForFile(file),
  onState: callback => ipcRenderer.on('deck:state', (_event, state) => callback(state)),
  onLog: callback => ipcRenderer.on('deck:log', (_event, entry) => callback(entry)),
  onFrame: callback => ipcRenderer.on('deck:frame', (_event, frame) => callback(frame))
});
