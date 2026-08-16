import { initializeTestEnvironment, assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import { readFileSync } from 'fs';
import { test, before, after, beforeEach } from 'node:test';

let testEnv;

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: 'saferoute-55bb6-test',
    firestore: {
      rules: readFileSync('../firestore.rules', 'utf8'),
      host: '127.0.0.1',
      port: 8088,
    },
  });
});

after(async () => {
  if (testEnv) {
    await testEnv.cleanup();
  }
});

beforeEach(async () => {
  if (testEnv) {
    await testEnv.clearFirestore();
  }
});

test('1. unauthenticated write to sos_broadcasts is rejected', async () => {
  const unauthDb = testEnv.unauthenticatedContext().firestore();
  await assertFails(
    unauthDb.collection('sos_broadcasts').add({
      victimUid: 'victim123',
      lat: 12.97,
      lng: 77.59,
    })
  );
});

test('2. authenticated user CAN create their own sos_broadcast', async () => {
  const aliceDb = testEnv.authenticatedContext('alice').firestore();
  await assertSucceeds(
    aliceDb.collection('sos_broadcasts').add({
      victimUid: 'alice',
      lat: 12.97,
      lng: 77.59,
    })
  );
});

test('3. authenticated user CANNOT read/write another user\'s emergencyContact fields', async () => {
  const aliceDb = testEnv.authenticatedContext('alice').firestore();
  await assertFails(
    aliceDb.collection('users').doc('bob').set({
      emergencyContact1: '+1234567890',
    })
  );
  await assertFails(
    aliceDb.collection('users').doc('bob').get()
  );
});

test('4. authenticated user CANNOT overwrite another user\'s sos_broadcast victimUid', async () => {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const adminDb = context.firestore();
    await adminDb.collection('sos_broadcasts').doc('bobs_sos').set({
      victimUid: 'bob',
      assignedResponder: null,
      lat: 12.97,
      lng: 77.59,
    });
  });

  const aliceDb = testEnv.authenticatedContext('alice').firestore();
  await assertFails(
    aliceDb.collection('sos_broadcasts').doc('bobs_sos').update({
      victimUid: 'alice',
    })
  );
});
