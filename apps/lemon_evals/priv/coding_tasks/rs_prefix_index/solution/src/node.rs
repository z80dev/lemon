use std::collections::BTreeMap;
use crate::Action;

#[derive(Debug, Clone, Default)]
pub(crate) struct Node {
    pub(crate) action: Option<Action>,
    pub(crate) children: BTreeMap<String, Node>,
}

impl Node {
    pub(crate) fn empty(&self) -> bool { self.action.is_none() && self.children.is_empty() }

    pub(crate) fn insert(&mut self, parts: &[&str], action: Action) -> Option<Action> {
        let mut node = self;
        for part in parts {
            if !node.children.contains_key(*part) {
                node.children.insert((*part).to_owned(), Node::default());
            }
            node = node.children.get_mut(*part).expect("child inserted above");
        }
        node.action.replace(action)
    }

    pub(crate) fn remove(&mut self, parts: &[&str]) -> Option<Action> {
        let Some((first, rest)) = parts.split_first() else { return self.action.take(); };
        let child = self.children.get_mut(*first)?;
        let removed = child.remove(rest);
        if child.empty() { self.children.remove(*first); }
        removed
    }
}
