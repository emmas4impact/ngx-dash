const appVersionName = String.fromEnvironment(
  'APP_VERSION_NAME',
  defaultValue: '1.13',
);
const appBuildNumber = String.fromEnvironment(
  'APP_BUILD_NUMBER',
  defaultValue: '1',
);
const appDisplayVersion = '$appVersionName.$appBuildNumber';
