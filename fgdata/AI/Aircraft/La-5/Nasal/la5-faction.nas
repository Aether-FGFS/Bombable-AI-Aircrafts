   ## faction

setlistener("/sim/signals/fdm-initialized", func {
  var myNode = cmdarg().getPath();
  var elapsed = 0;
  var trySet = func {
    if (contains(bombable.attributes, myNode)) {
      bombable.attributes[myNode].faction = "A";
    } else {
      elapsed += 1;
      if (elapsed < 40) settimer(trySet, 1);
    }
  };
  settimer(trySet, 2);
});