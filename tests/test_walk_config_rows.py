"""Test _walk_config_rows_recursive — confirms it overflows on deep SwiftUI AX trees."""
import sys
from unittest.mock import MagicMock

# Mock ApplicationServices BEFORE importing stash_switch_config
sys.modules['ApplicationServices'] = MagicMock()
# Quartz.CoreGraphics is only imported inside close_config_window, but mock it too
sys.modules['Quartz'] = MagicMock()
sys.modules['Quartz.CoreGraphics'] = MagicMock()

import pytest

# Now safe to import
sys.path.insert(0, '/Users/niu/Library/Mobile Documents/com~apple~CloudDocs/hermes-projects/stash-vpn-monitor')
from stash_switch_config import _walk_config_rows_recursive


def _make_deep_mock_tree(depth=1500, leaf_label='SsdAirport'):
    """Build a mock AX tree deeper than Python's default recursion limit (1000).

    Each level wraps the next as an AXGroup with a single AXStaticText child
    containing a generic label, except the innermost which carries the target keyword.
    """
    # innermost: the config row we're looking for
    inner = MagicMock()
    group = MagicMock()
    static_text = MagicMock()

    # Mock AXChildren: group has one static_text child
    group.ax_role = 'AXGroup'
    group.ax_children = [static_text]
    static_text.ax_role = 'AXStaticText'
    static_text.ax_label = leaf_label

    inner.ax_role = 'AXGroup'
    inner.ax_children = [group]
    # The group is what matters — the inner element just wraps it

    # Actually, let me rethink. A valid AXGroup row has:
    # - role == 'AXGroup'
    # - children containing exactly one AXStaticText with a label
    # The "root_elem" is just the starting point we pass to walk.
    # We want a chain: root -> AXGroup -> AXGroup -> ... -> AXGroup(target)
    # Each intermediate AXGroup has non-target children to force deeper traversal.
    # But the simplest failing case: a deeply nested chain where the innermost
    # child has the right structure (AXGroup with one AXStaticText).
    pass


class FakeAXElem:
    """Reusable fake AX element for test trees."""
    def __init__(self, role='AXGroup', children=None, label=''):
        self.ax_role = role
        self.ax_children = children or []
        self.ax_label = label


def _build_deep_chain(depth, leaf_label='SsdAirport'):
    """Build a chain: root -> group -> group -> ... -> group(target).

    All intermediate groups have children that are just AXGroup with no text,
    so they don't match the config keyword filter. The leaf is a proper row.
    """
    # Leaf: the matching config row
    st = FakeAXElem(role='AXStaticText', label=leaf_label)
    leaf = FakeAXElem(role='AXGroup', children=[st])

    # Build chain backward from leaf
    current = leaf
    for _ in range(depth - 1):
        # Each intermediate level: just a plain AXGroup wrapping the next level
        # Its children are [current], which has role AXGroup with no label match
        current = FakeAXElem(role='AXGroup', children=[current])

    return current  # root


def _ax_children(elem):
    return elem.ax_children


def _ax_role(elem):
    return elem.ax_role


def _ax_label(elem):
    return elem.ax_label


class TestRecursiveWalkDeepTree:

    def test_recursive_overflows_on_deep_tree(self):
        """A tree deeper than Python's recursion limit should raise RecursionError."""
        depth = 1500  # > default recursion limit of 1000
        root = _build_deep_chain(depth)

        keywords = ['ssdairport']

        with pytest.raises(RecursionError):
            _walk_config_rows_recursive(root, keywords, _ax_children, _ax_role, _ax_label)

    def test_recursive_succeeds_on_shallow_tree(self):
        """A shallow tree should work fine with the recursive walk."""
        root = _build_deep_chain(10)
        keywords = ['ssdairport']

        rows = _walk_config_rows_recursive(root, keywords, _ax_children, _ax_role, _ax_label)
        assert len(rows) == 1
        label, group_elem, st_elem = rows[0]
        assert 'ssdairport' in label.lower()
