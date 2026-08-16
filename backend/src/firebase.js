import admin from 'firebase-admin';

import { config } from './config.js';

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

function resolveCredential() {
  if (config.firebase?.serviceAccountJson) {
    try {
      return admin.credential.cert(JSON.parse(config.firebase.serviceAccountJson));
    } catch {
      // If path string was provided instead of raw JSON
      if (fs.existsSync(config.firebase.serviceAccountJson)) {
        const fileContent = JSON.parse(fs.readFileSync(config.firebase.serviceAccountJson, 'utf8'));
        return admin.credential.cert(fileContent);
      }
    }
  }

  // Fallback: search backend root folder for service account JSON
  const backendDir = path.resolve(__dirname, '..');
  const files = fs.readdirSync(backendDir);
  const keyFile = files.find(f => f.includes('firebase-adminsdk') && f.endsWith('.json'));
  if (keyFile) {
    const filePath = path.join(backendDir, keyFile);
    const serviceAccount = JSON.parse(fs.readFileSync(filePath, 'utf8'));
    return admin.credential.cert(serviceAccount);
  }

  return admin.credential.applicationDefault();
}

if (!admin.apps.length) {
  admin.initializeApp({
    credential: resolveCredential(),
  });
}

export const firestore = admin.firestore();
export { admin };
