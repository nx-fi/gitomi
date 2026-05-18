const detail = @import("pulls/detail.zig");
const form = @import("pulls/form.zig");

pub const renderPullsPage = detail.renderPullsPage;
pub const renderPullDetailPage = detail.renderPullDetailPage;
pub const renderPullMergeEditorPage = detail.renderPullMergeEditorPage;
pub const renderPullForm = form.renderPullForm;
pub const handlePullPost = form.handlePullPost;
pub const handlePullConflictPost = detail.handlePullConflictPost;
pub const handlePullMergePost = detail.handlePullMergePost;
pub const handlePullBulkPost = detail.handlePullBulkPost;
pub const handlePullChecklistPost = detail.handlePullChecklistPost;
pub const handlePullCommentPost = detail.handlePullCommentPost;
pub const handlePullNotificationPost = detail.handlePullNotificationPost;
pub const handlePullSidebarPost = detail.handlePullSidebarPost;
