use super::Platform;

pub struct CurrentPlatform;

impl Platform for CurrentPlatform {
    fn os_name(&self) -> &'static str {
        "linux"
    }
}
