const appVersionName = String.fromEnvironment(
  'APP_VERSION_NAME',
  defaultValue: '1.0.12',
);
const appBuildNumber = String.fromEnvironment(
  'APP_BUILD_NUMBER',
  defaultValue: '13',
);
const appDisplayVersion = '$appVersionName.$appBuildNumber';
