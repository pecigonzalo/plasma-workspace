/*
 * Copyright 2019 Kai Uwe Broulik <kde@privat.broulik.de>
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation; either version 2 of
 * the License or (at your option) version 3 or any later version
 * accepted by the membership of KDE e.V. (or its successor approved
 * by the membership of KDE e.V.), which shall act as a proxy
 * defined in Section 14 of version 3 of the license.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>
 */

pragma Singleton
import QtQuick 2.8
import QtQuick.Window 2.12
import QtQuick.Layouts 1.1

import org.kde.plasma.plasmoid 2.0
import org.kde.plasma.core 2.0 as PlasmaCore
import org.kde.kquickcontrolsaddons 2.0
import org.kde.kirigami 2.11 as Kirigami

import org.kde.notificationmanager 1.0 as NotificationManager
import org.kde.taskmanager 0.1 as TaskManager

import org.kde.plasma.private.notifications 2.0 as Notifications

import ".."

// This singleton object contains stuff shared between all notification plasmoids, namely:
// - Popup creation and placement
// - Do not disturb mode
QtObject {
    id: globals

    // Listened to by "ago" label in NotificationHeader to update all of them in unison
    signal timeChanged

    property bool inhibited: false

    onInhibitedChanged: {
        var pa = pulseAudio.item;
        if (!pa) {
            return;
        }

        var stream = pa.notificationStream;
        if (!stream) {
            return;
        }

        if (inhibited) {
            // Only remember that we muted if previously not muted.
            if (!stream.muted) {
                notificationSettings.notificationSoundsInhibited = true;
                stream.mute();
            }
        } else {
            // Only unmute if we previously muted it.
            if (notificationSettings.notificationSoundsInhibited) {
                stream.unmute();
            }
            notificationSettings.notificationSoundsInhibited = false;
        }
        notificationSettings.save();
    }

    // Some parts of the code rely on plasmoid.nativeInterface and since we're in a singleton here
    // this is named "plasmoid"
    property QtObject plasmoid: plasmoids[0]

    // HACK When a plasmoid is destroyed, QML sets its value to "null" in the Array
    // so we then remove it so we have a working "plasmoid" again
    onPlasmoidChanged: {
        if (!plasmoid) {
            // this doesn't emit a change, only in ratePlasmoids() it will detect the change
            plasmoids.splice(0, 1); // remove first
            ratePlasmoids();
        }
    }

    // all notification plasmoids
    property var plasmoids: []

    property int popupLocation: {
        // if we are on mobile, we can ignore the settings totally and just
        // align it to top center
        if (Kirigami.Settings.isMobile) {
            return Qt.AlignTop | Qt.AlignHCenter;
        }
        switch (notificationSettings.popupPosition) {
        // Auto-determine location based on plasmoid location
        case NotificationManager.Settings.CloseToWidget:
            if (!plasmoid) {
                return Qt.AlignBottom | Qt.AlignRight; // just in case
            }

            var alignment = 0;
            if (plasmoid.location === PlasmaCore.Types.LeftEdge) {
                alignment |= Qt.AlignLeft;
            } else if (plasmoid.location === PlasmaCore.Types.RightEdge) {
                alignment |= Qt.AlignRight;
            // No horizontal alignment flag has it place it left or right depending on
            // which half of the *panel* the notification plasmoid is in
            }

            if (plasmoid.location === PlasmaCore.Types.TopEdge) {
                alignment |= Qt.AlignTop;
            } else if (plasmoid.location === PlasmaCore.Types.BottomEdge) {
                alignment |= Qt.AlignBottom;
            // No vertical alignment flag has it place it top or bottom edge depending on
            // which half of the *screen* the notification plasmoid is in
            }
            return alignment;

        case NotificationManager.Settings.TopLeft:
            return Qt.AlignTop | Qt.AlignLeft;
        case NotificationManager.Settings.TopCenter:
            return Qt.AlignTop | Qt.AlignHCenter;
        case NotificationManager.Settings.TopRight:
            return Qt.AlignTop | Qt.AlignRight;
        case NotificationManager.Settings.BottomLeft:
            return Qt.AlignBottom | Qt.AlignLeft;
        case NotificationManager.Settings.BottomCenter:
            return Qt.AlignBottom | Qt.AlignHCenter;
        case NotificationManager.Settings.BottomRight:
            return Qt.AlignBottom | Qt.AlignRight;
        }
    }

    readonly property rect screenRect: {
        if (!plasmoid) {
            return Qt.rect(0, 0, -1, -1);
        }

        let rect = Qt.rect(plasmoid.screenGeometry.x + plasmoid.availableScreenRect.x,
                           plasmoid.screenGeometry.y + plasmoid.availableScreenRect.y,
                           plasmoid.availableScreenRect.width,
                           plasmoid.availableScreenRect.height);

        // When no explicit screen corner is configured,
        // restrict notification popup position by horizontal panel width
        if (notificationSettings.popupPosition === NotificationManager.Settings.CloseToWidget
            && plasmoid.formFactor === PlasmaCore.Types.Horizontal) {
            const visualParentWindow = visualParent.Window.window;
            if (visualParentWindow) {
                const left = Math.max(rect.left, visualParentWindow.x);
                const right = Math.min(rect.right, visualParentWindow.x + visualParentWindow.width);
                rect = Qt.rect(left, rect.y, right - left, rect.height);
            }
        }

        return rect;
    }
    onScreenRectChanged: repositionTimer.start()

    readonly property Item visualParent: {
        if (!plasmoid) {
            return null;
        }
        return plasmoid.nativeInterface.systemTrayRepresentation
            || plasmoid.compactRepresentationItem
            || plasmoid.fullRepresentationItem;
    }
    onVisualParentChanged: positionPopups()

    readonly property QtObject focusDialog: plasmoid.nativeInterface.focussedPlasmaDialog
    onFocusDialogChanged: positionPopups()

    // The raw width of the popup's content item, the Dialog itself adds some margins
    // Make it wider when on the top or the bottom center, since there's more horizontal
    // space available without looking weird
    // On mobile however we don't really want to have larger notifications
    property int popupWidth: (popupLocation & Qt.AlignHCenter) && !Kirigami.Settings.isMobile ? units.gridUnit * 28 : units.gridUnit * 18
    property int popupEdgeDistance: units.largeSpacing * 2
    // Reduce spacing between popups when centered so the stack doesn't intrude into the
    // view as much
    property int popupSpacing: (popupLocation & Qt.AlignHCenter) && !Kirigami.Settings.isMobile ? units.smallSpacing : units.largeSpacing

    // How much vertical screen real estate the notification popups may consume
    readonly property real popupMaximumScreenFill: 0.75

    onPopupLocationChanged: Qt.callLater(positionPopups)

    Component.onCompleted: checkInhibition()

    function adopt(plasmoid) {
        // this doesn't emit a change, only in ratePlasmoids() it will detect the change
        globals.plasmoids.push(plasmoid);
        ratePlasmoids();
    }

    // Sorts plasmoids based on a heuristic to find a suitable plasmoid to follow when placing popups
    function ratePlasmoids() {
        var plasmoidScore = function(plasmoid) {
            if (!plasmoid) {
                return 0;
            }

            var score = 0;

            // Prefer plasmoids in a panel, prefer horizontal panels over vertical ones
            if (plasmoid.location === PlasmaCore.Types.LeftEdge
                    || plasmoid.location === PlasmaCore.Types.RightEdge) {
                score += 1;
            } else if (plasmoid.location === PlasmaCore.Types.TopEdge
                       || plasmoid.location === PlasmaCore.Types.BottomEdge) {
                score += 2;
            }

            // Prefer iconified plasmoids
            if (!plasmoid.expanded) {
                ++score;
            }

            // Prefer plasmoids on primary screen
            if (plasmoid.nativeInterface && plasmoid.nativeInterface.isPrimaryScreen(plasmoid.screenGeometry)) {
                ++score;
            }

            return score;
        }

        var newPlasmoids = plasmoids;
        newPlasmoids.sort(function (a, b) {
            var scoreA = plasmoidScore(a);
            var scoreB = plasmoidScore(b);
            // Sort descending by score
            if (scoreA < scoreB) {
                return 1;
            } else if (scoreA > scoreB) {
                return -1;
            } else {
                return 0;
            }
        });
        globals.plasmoids = newPlasmoids;
    }

    function checkInhibition() {
        globals.inhibited = Qt.binding(function() {
            var inhibited = false;

            if (!NotificationManager.Server.valid) {
                return false;
            }

            var inhibitedUntil = notificationSettings.notificationsInhibitedUntil;
            if (!isNaN(inhibitedUntil.getTime())) {
                inhibited |= (new Date().getTime() < inhibitedUntil.getTime());
            }

            if (notificationSettings.notificationsInhibitedByApplication) {
                inhibited |= true;
            }

            if (notificationSettings.inhibitNotificationsWhenScreensMirrored) {
                inhibited |= notificationSettings.screensMirrored;
            }

            return inhibited;
        });
    }

    function revokeInhibitions() {
        notificationSettings.notificationsInhibitedUntil = undefined;
        notificationSettings.revokeApplicationInhibitions();
        // overrules current mirrored screen setup, updates again when screen configuration changes
        notificationSettings.screensMirrored = false;

        notificationSettings.save();
    }

    function rectIntersect(rect1 /*dialog*/, rect2 /*popup*/) {
        return rect1.x < rect2.x + rect2.width
                && rect2.x < rect1.x + rect1.width
                && rect1.y < rect2.y + rect2.height
                && rect2.y < rect1.y + rect1.height;
    }

    function positionPopups() {
        if (!plasmoid) {
            return;
        }

        const screenRect = globals.screenRect;
        if (screenRect.width <= 0 || screenRect.height <= 0) {
            return;
        }

        let effectivePopupLocation = popupLocation;

        const visualParent = globals.visualParent;
        const visualParentWindow = visualParent.Window.window;

        // When no horizontal alignment is specified, place it depending on which half of the *panel*
        // the notification plasmoid is in
        if (visualParentWindow) {
            if (!(effectivePopupLocation & (Qt.AlignLeft | Qt.AlignHCenter | Qt.AlignRight))) {
                const iconHCenter = visualParent.mapToItem(null /*mapToScene*/, 0, 0).x + visualParent.width / 2;

                if (iconHCenter < visualParentWindow.width / 2) {
                    effectivePopupLocation |= Qt.AlignLeft;
                } else {
                    effectivePopupLocation |= Qt.AlignRight;
                }
            }
        }

        // When no vertical alignment is specified, place it depending on which half of the *screen*
        // the notification plasmoid is in
        if (!(effectivePopupLocation & (Qt.AlignTop | Qt.AlignBottom))) {
            const screenVCenter = screenRect.y + screenRect.height / 2;
            const iconVCenter = visualParent.mapToGlobal(0, visualParent.height / 2).y;

            if (iconVCenter < screenVCenter) {
                effectivePopupLocation |= Qt.AlignTop;
            } else {
                effectivePopupLocation |= Qt.AlignBottom;
            }
        }

        let y = screenRect.y;
        if (effectivePopupLocation & Qt.AlignBottom) {
            y += screenRect.height - popupEdgeDistance;
        } else {
            y += popupEdgeDistance;
        }

        for (var i = 0; i < popupInstantiator.count; ++i) {
            let popup = popupInstantiator.objectAt(i);
            // Popup width is fixed, so don't rely on the actual window size
            var popupEffectiveWidth = popupWidth + popup.margins.left + popup.margins.right;

            const leftMostX = screenRect.x + popupEdgeDistance;
            const rightMostX = screenRect.x + screenRect.width - popupEdgeDistance - popupEffectiveWidth;

            // If available screen rect is narrower than the popup, center it in the available rect
            if (screenRect.width < popupEffectiveWidth || effectivePopupLocation & Qt.AlignHCenter) {
                popup.x = screenRect.x + (screenRect.width - popupEffectiveWidth) / 2
            } else if (effectivePopupLocation & Qt.AlignLeft) {
                popup.x = leftMostX;
            } else if (effectivePopupLocation & Qt.AlignRight) {
                popup.x = rightMostX;
            }

            if (effectivePopupLocation & Qt.AlignTop) {
                // We want to calculate the new position based on its original target position to avoid positioning it and then
                // positioning it again, hence the temporary Qt.rect with explicit "y" and not just the popup as a whole
                if (focusDialog && focusDialog.visible && !(focusDialog instanceof NotificationPopup)
                        && rectIntersect(focusDialog, Qt.rect(popup.x, y, popup.width, popup.height))) {
                    y = focusDialog.y + focusDialog.height + popupEdgeDistance;
                }
                popup.y = y;
                // If the popup isn't ready yet, ignore its occupied space for now.
                // We'll reposition everything in onHeightChanged eventually.
                y += popup.height + (popup.height > 0 ? popupSpacing : 0);
            } else {
                y -= popup.height;
                if (focusDialog && focusDialog.visible && !(focusDialog instanceof NotificationPopup)
                        && rectIntersect(focusDialog, Qt.rect(popup.x, y, popup.width, popup.height))) {
                    y = focusDialog.y - popup.height - popupEdgeDistance;
                }
                popup.y = y;
                if (popup.height > 0) {
                    y -= popupSpacing;
                }
            }

            // don't let notifications take more than popupMaximumScreenFill of the screen
            var visible = true;
            if (i > 0) { // however always show at least one popup
                if (effectivePopupLocation & Qt.AlignTop) {
                    visible = (popup.y + popup.height < screenRect.y + (screenRect.height * popupMaximumScreenFill));
                } else {
                    visible = (popup.y > screenRect.y + (screenRect.height * (1 - popupMaximumScreenFill)));
                }
            }

            popup.visible = visible;
        }
    }

    property QtObject popupNotificationsModel: NotificationManager.Notifications {
        limit: plasmoid ? (Math.ceil(globals.screenRect.height / (theme.mSize(theme.defaultFont).height * 4))) : 0
        showExpired: false
        showDismissed: false
        blacklistedDesktopEntries: notificationSettings.popupBlacklistedApplications
        blacklistedNotifyRcNames: notificationSettings.popupBlacklistedServices
        whitelistedDesktopEntries: globals.inhibited ? notificationSettings.doNotDisturbPopupWhitelistedApplications : []
        whitelistedNotifyRcNames: globals.inhibited ? notificationSettings.doNotDisturbPopupWhitelistedServices : []
        showJobs: notificationSettings.jobsInNotifications
        sortMode: NotificationManager.Notifications.SortByTypeAndUrgency
        sortOrder: Qt.AscendingOrder
        groupMode: NotificationManager.Notifications.GroupDisabled
        urgencies: {
            var urgencies = 0;

            // Critical always except in do not disturb mode when disabled in settings
            if (!globals.inhibited || notificationSettings.criticalPopupsInDoNotDisturbMode) {
                urgencies |= NotificationManager.Notifications.CriticalUrgency;
            }

            // Normal only when not in do not disturb mode
            if (!globals.inhibited) {
                urgencies |= NotificationManager.Notifications.NormalUrgency;
            }

            // Low only when enabled in settings and not in do not disturb mode
            if (!globals.inhibited && notificationSettings.lowPriorityPopups) {
                urgencies |=NotificationManager.Notifications.LowUrgency;
            }

            return urgencies;
        }
    }

    property QtObject notificationSettings: NotificationManager.Settings {
        onNotificationsInhibitedUntilChanged: globals.checkInhibition()
    }

    property QtObject tasksModel: TaskManager.TasksModel {
        groupMode: TaskManager.TasksModel.GroupApplications
        groupInline: false
    }

    // This periodically checks whether do not disturb mode timed out and updates the "minutes ago" labels
    property QtObject timeSource: PlasmaCore.DataSource {
        engine: "time"
        connectedSources: ["Local"]
        interval: 60000 // 1 min
        intervalAlignment: PlasmaCore.Types.AlignToMinute
        onDataChanged: {
            checkInhibition();
            globals.timeChanged();
        }
    }

    property Instantiator popupInstantiator: Instantiator {
        model: popupNotificationsModel
        delegate: NotificationPopup {
            // so Instantiator can access that after the model row is gone
            readonly property var notificationId: model.notificationId

            popupWidth: globals.popupWidth
            type: model.urgency === NotificationManager.Notifications.CriticalUrgency && notificationSettings.keepCriticalAlwaysOnTop
                  ? PlasmaCore.Dialog.CriticalNotification : PlasmaCore.Dialog.Notification

            notificationType: model.type

            applicationName: model.applicationName
            applicationIconSource: model.applicationIconName
            originName: model.originName || ""

            time: model.updated || model.created

            configurable: model.configurable
            // For running jobs instead of offering a "close" button that might lead the user to
            // think that will cancel the job, we offer a "dismiss" button that hides it in the history
            dismissable: model.type === NotificationManager.Notifications.JobType
                && model.jobState !== NotificationManager.Notifications.JobStateStopped
            // TODO would be nice to be able to "pin" jobs when they autohide
                && notificationSettings.permanentJobPopups
            closable: model.closable

            summary: model.summary
            body: model.body || ""
            icon: model.image || model.iconName
            hasDefaultAction: model.hasDefaultAction || false
            timeout: model.timeout
            // Increase default timeout for notifications with a URL so you have enough time
            // to interact with the thumbnail or bring the window to the front where you want to drag it into
            defaultTimeout: notificationSettings.popupTimeout + (model.urls && model.urls.length > 0 ? 5000 : 0)
            // When configured to not keep jobs open permanently, we autodismiss them after the standard timeout
            dismissTimeout: !notificationSettings.permanentJobPopups
                            && model.type === NotificationManager.Notifications.JobType
                            && model.jobState !== NotificationManager.Notifications.JobStateStopped
                            ? defaultTimeout : 0

            urls: model.urls || []
            urgency: model.urgency || NotificationManager.Notifications.NormalUrgency

            jobState: model.jobState || 0
            percentage: model.percentage || 0
            jobError: model.jobError || 0
            suspendable: !!model.suspendable
            killable: !!model.killable
            jobDetails: model.jobDetails || null

            configureActionLabel: model.configureActionLabel || ""
            actionNames: model.actionNames
            actionLabels: model.actionLabels

            hasReplyAction: model.hasReplyAction || false
            replyActionLabel: model.replyActionLabel || ""
            replyPlaceholderText: model.replyPlaceholderText || ""
            replySubmitButtonText: model.replySubmitButtonText || ""
            replySubmitButtonIconName: model.replySubmitButtonIconName || ""

            onExpired: popupNotificationsModel.expire(popupNotificationsModel.index(index, 0))
            onHoverEntered: model.read = true
            onCloseClicked: popupNotificationsModel.close(popupNotificationsModel.index(index, 0))
            onDismissClicked: model.dismissed = true
            onConfigureClicked: popupNotificationsModel.configure(popupNotificationsModel.index(index, 0))
            onDefaultActionInvoked: {
                if (defaultActionFallbackWindowIdx) {
                    if (!defaultActionFallbackWindowIdx.valid) {
                        console.warn("Failed fallback notification activation as window no longer exists");
                        return;
                    }

                    // When it's a group, activate the window highest in stacking order (presumably last used)
                    if (tasksModel.data(defaultActionFallbackWindowIdx, TaskManager.AbstractTasksModel.IsGroupParent)) {
                        let highestStacking = -1;
                        let highestIdx = undefined;

                        for (let i = 0; i < tasksModel.rowCount(defaultActionFallbackWindowIdx); ++i) {
                            const idx = tasksModel.index(i, 0, defaultActionFallbackWindowIdx);

                            const stacking = tasksModel.data(idx, TaskManager.AbstractTasksModel.StackingOrder);

                            if (stacking > highestStacking) {
                                highestStacking = stacking;
                                highestIdx = tasksModel.makePersistentModelIndex(defaultActionFallbackWindowIdx.row, i);
                            }
                        }

                        if (highestIdx && highestIdx.valid) {
                            tasksModel.requestActivate(highestIdx);
                            popupNotificationsModel.close(popupNotificationsModel.index(index, 0));

                        }
                        return;
                    }

                    tasksModel.requestActivate(defaultActionFallbackWindowIdx);
                    popupNotificationsModel.close(popupNotificationsModel.index(index, 0));
                    return;
                }

                popupNotificationsModel.invokeDefaultAction(popupNotificationsModel.index(index, 0))
                popupNotificationsModel.close(popupNotificationsModel.index(index, 0))
            }
            onActionInvoked: {
                popupNotificationsModel.invokeAction(popupNotificationsModel.index(index, 0), actionName)
                popupNotificationsModel.close(popupNotificationsModel.index(index, 0))
            }
            onReplied: {
                popupNotificationsModel.reply(popupNotificationsModel.index(index, 0), text);
                popupNotificationsModel.close(popupNotificationsModel.index(index, 0));
            }
            onOpenUrl: {
                Qt.openUrlExternally(url);
                popupNotificationsModel.close(popupNotificationsModel.index(index, 0))
            }
            onFileActionInvoked: popupNotificationsModel.close(popupNotificationsModel.index(index, 0))

            onSuspendJobClicked: popupNotificationsModel.suspendJob(popupNotificationsModel.index(index, 0))
            onResumeJobClicked: popupNotificationsModel.resumeJob(popupNotificationsModel.index(index, 0))
            onKillJobClicked: popupNotificationsModel.killJob(popupNotificationsModel.index(index, 0))

            // popup width is fixed
            onHeightChanged: positionPopups()

            Component.onCompleted: {
                if (model.type === NotificationManager.Notifications.NotificationType && model.desktopEntry) {
                    // Register apps that were seen spawning a popup so they can be configured later
                    // Apps with notifyrc can already be configured anyway
                    if (!model.notifyRcName) {
                        notificationSettings.registerKnownApplication(model.desktopEntry);
                        notificationSettings.save();
                    }

                    // If there is no default action, check if there is a window we could activate instead
                    if (!model.hasDefaultAction) {
                        for (let i = 0; i < tasksModel.rowCount(); ++i) {
                            const idx = tasksModel.index(i, 0);

                            const appId = tasksModel.data(idx, TaskManager.AbstractTasksModel.AppId);
                            if (appId === model.desktopEntry + ".desktop") {
                                // Takes a row number, not a QModelIndex
                                defaultActionFallbackWindowIdx = tasksModel.makePersistentModelIndex(i);
                                hasDefaultAction = true;
                                break;
                            }
                        }
                    }
                }

                // Tell the model that we're handling the timeout now
                popupNotificationsModel.stopTimeout(popupNotificationsModel.index(index, 0));
            }
        }
        onObjectAdded: {
            positionPopups();
            object.visible = true;
        }
        onObjectRemoved: {
            var notificationId = object.notificationId
            // Popup might have been destroyed because of a filter change, tell the model to do the timeout work for us again
            // cannot use QModelIndex here as the model row is already gone
            popupNotificationsModel.startTimeout(notificationId);

            positionPopups();
        }
    }

    // TODO use pulseaudio-qt for this once it becomes a framework
    property QtObject pulseAudio: Loader {
        source: "PulseAudio.qml"
    }

    // Normally popups are repositioned through Qt.callLater but in case of e.g. screen geometry changes we want to compress that
    property Timer repositionTimer: Timer {
        interval: 250
        onTriggered: positionPopups()
    }

    // Tracks the visual parent's window since mapToItem cannot signal
    // so that when user resizes panel we reposition the popups live
    property Connections visualParentWindowConnections: Connections {
        target: visualParent ? visualParent.Window.window : null
        function onXChanged() {
            repositionTimer.start();
        }
        function onYChanged() {
            repositionTimer.start();
        }
        function onWidthChanged() {
            repositionTimer.start();
        }
        function onHeightChanged() {
            repositionTimer.start();
        }
    }

    // Keeps the Inhibited property on DBus in sync with our inhibition handling
    property Binding serverInhibitedBinding: Binding {
        target: NotificationManager.Server
        property: "inhibited"
        value: globals.inhibited
    }

    function toggleDoNotDisturbMode() {
        var oldInhibited = globals.inhibited;
        if (oldInhibited) {
            globals.revokeInhibitions();
        } else {
            // Effectively "in a year" is "until turned off"
            var d = new Date();
            d.setFullYear(d.getFullYear() + 1);
            notificationSettings.notificationsInhibitedUntil = d;
            notificationSettings.save();
        }

        checkInhibition();

        if (globals.inhibited !== oldInhibited) {
            shortcuts.showDoNotDisturbOsd(globals.inhibited);
        }
    }

    property Notifications.GlobalShortcuts shortcuts: Notifications.GlobalShortcuts {
        onToggleDoNotDisturbTriggered: globals.toggleDoNotDisturbMode()
    }
}
