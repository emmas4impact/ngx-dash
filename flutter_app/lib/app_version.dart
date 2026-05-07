const appVersionName = String.fromEnvironment(
  'APP_VERSION_NAME',
  defaultValue: '1.1.1',
);
const appBuildNumber = String.fromEnvironment(
  'APP_BUILD_NUMBER',
  defaultValue: '17',
);
const appDisplayVersion = appVersionName;
