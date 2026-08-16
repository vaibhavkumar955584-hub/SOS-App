import 'dotenv/config';

export const config = {
  port: Number(process.env.PORT ?? 8080),
  firebase: {
    serviceAccountJson: process.env.FIREBASE_SERVICE_ACCOUNT_JSON,
  },
};
