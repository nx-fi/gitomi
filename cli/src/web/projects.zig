const detail = @import("projects/detail.zig");
const form = @import("projects/form.zig");
const items = @import("projects/items.zig");
const overview = @import("projects/overview.zig");

pub const renderProjectsPage = detail.renderProjectsPage;
pub const renderProjectForm = form.renderProjectForm;
pub const renderProjectFormFromTarget = form.renderProjectFormFromTarget;
pub const handleProjectPost = form.handleProjectPost;
pub const handleProjectItemPost = items.handleProjectItemPost;
pub const handleProjectPropertiesPost = overview.handleProjectPropertiesPost;
pub const handleProjectDefaultViewPost = overview.handleProjectDefaultViewPost;
pub const handleProjectCommentPost = overview.handleProjectCommentPost;
