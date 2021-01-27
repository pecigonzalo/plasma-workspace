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

import QtQuick 2.8

import org.kde.plasma.core 2.0 as PlasmaCore
import org.kde.plasma.components 2.0 as PlasmaComponents // For ContextMenu

import org.kde.kquickcontrolsaddons 2.0 as KQCAddons

PlasmaComponents.ContextMenu {
    id: contextMenu

    signal closed

    property QtObject __clipboard: KQCAddons.Clipboard { }

    // can be a Text or TextEdit
    property Item target

    property string link

    onStatusChanged: {
        if (status === PlasmaComponents.DialogStatus.Closed) {
            closed();
        }
    }

    PlasmaComponents.MenuItem {
        text: i18nd("plasma_applet_org.kde.plasma.notifications", "Copy Link Address")
        onClicked: __clipboard.content = contextMenu.link
        visible: contextMenu.link !== ""
    }

    PlasmaComponents.MenuItem {
        separator: true
        visible: contextMenu.link !== ""
    }

    PlasmaComponents.MenuItem {
        text: i18nd("plasma_applet_org.kde.plasma.notifications", "Copy")
        icon: "edit-copy"
        enabled: typeof target.selectionStart !== "undefined"
        ? target.selectionStart !== target.selectionEnd
        : (target.text || "").length > 0
        onClicked: {
            if (typeof target.copy === "function") {
                target.copy();
            } else {
                __clipboard.content = target.text;
            }
        }
    }

    PlasmaComponents.MenuItem {
        id: selectAllAction
        icon: "edit-select-all"
        text: i18nd("plasma_applet_org.kde.plasma.notifications", "Select All")
        onClicked: target.selectAll()
        visible: typeof target.selectAll === "function"
    }
}
