"""Regression tests for Stash AX config-row traversal."""
import sys
import weakref
from unittest.mock import MagicMock

import pytest

# The production module imports macOS ApplicationServices at module import time.
sys.modules['ApplicationServices'] = MagicMock()

import stash_switch_config as switcher


class FakeAXElem:
    """Minimal AX element used to build deterministic test hierarchies."""

    def __init__(self, role='AXGroup', children=None, label=''):
        self.ax_role = role
        self.ax_children = children if children is not None else []
        self.ax_label = label


def _build_deep_chain(depth, leaf_label='SsdAirport'):
    """Build a chain whose leaf is a matching config row."""
    static_text = FakeAXElem(role='AXStaticText', label=leaf_label)
    current = FakeAXElem(role='AXGroup', children=[static_text])

    for _ in range(depth - 1):
        current = FakeAXElem(role='AXGroup', children=[current])

    return current


def _ax_children(elem):
    return elem.ax_children


def _ax_role(elem):
    return elem.ax_role


def _ax_label(elem):
    return elem.ax_label


@pytest.fixture(autouse=True)
def _mock_ax_helpers(monkeypatch):
    monkeypatch.setattr(switcher, 'get_all_configs', lambda: ['SsdAirport', 'glados'])
    monkeypatch.setattr(switcher, 'ax_children', _ax_children)
    monkeypatch.setattr(switcher, 'ax_role', _ax_role)
    monkeypatch.setattr(switcher, 'ax_label', _ax_label)


def test_get_config_rows_handles_tree_deeper_than_recursion_limit():
    root = _build_deep_chain(1500)

    rows = switcher.get_config_rows(root)

    assert [label for label, _, _ in rows] == ['SsdAirport']


def test_get_config_rows_preserves_depth_first_order_and_row_elements():
    glados_text = FakeAXElem(role='AXStaticText', label='glados')
    glados = FakeAXElem(role='AXGroup', children=[glados_text])
    airport_text = FakeAXElem(role='AXStaticText', label='SsdAirport')
    airport = FakeAXElem(role='AXGroup', children=[airport_text])
    root = FakeAXElem(children=[glados, airport])

    rows = switcher.get_config_rows(root)

    assert rows == [
        ('glados', glados, glados_text),
        ('SsdAirport', airport, airport_text),
    ]


def test_get_config_rows_handles_cycle_without_duplicate_rows():
    target = FakeAXElem(
        role='AXGroup',
        children=[FakeAXElem(role='AXStaticText', label='glados')],
    )
    root = FakeAXElem()
    root.ax_children = [root, target]

    rows = switcher.get_config_rows(root)

    assert [label for label, _, _ in rows] == ['glados']


def test_get_config_rows_keeps_visited_elements_alive(monkeypatch):
    """Prevent Python id reuse while dynamically-created AX proxies are traversed."""
    first_child_ref = None

    class DynamicElem:
        def __init__(self, level):
            self.level = level

    def dynamic_children(elem):
        nonlocal first_child_ref
        if elem.level == 0:
            child = DynamicElem(1)
            first_child_ref = weakref.ref(child)
            return [child]
        if elem.level == 1:
            return [DynamicElem(2)]

        assert first_child_ref is not None
        assert first_child_ref() is not None
        return []

    monkeypatch.setattr(switcher, 'ax_children', dynamic_children)
    monkeypatch.setattr(switcher, 'ax_role', lambda _elem: 'AXGroup')

    assert switcher.get_config_rows(DynamicElem(0)) == []


def test_get_config_rows_returns_empty_when_no_config_matches():
    root = _build_deep_chain(100, leaf_label='NotAConfig')

    assert switcher.get_config_rows(root) == []


def test_get_config_rows_skips_role_lookup_for_childless_elements(monkeypatch):
    def unexpected_ax_role(_elem):
        raise AssertionError('ax_role should not be called for childless elements')

    monkeypatch.setattr(switcher, 'ax_role', unexpected_ax_role)

    assert switcher.get_config_rows(FakeAXElem(children=[])) == []


def test_get_config_rows_propagates_ax_failures(monkeypatch):
    def failing_ax_children(_elem):
        raise RuntimeError('AXChildren unavailable')

    monkeypatch.setattr(switcher, 'ax_children', failing_ax_children)

    with pytest.raises(RuntimeError, match='AXChildren unavailable'):
        switcher.get_config_rows(FakeAXElem())
