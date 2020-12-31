using Microsoft.VisualStudio.TestTools.UnitTesting;
using Server.Actions;
using Server.Elements;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace ServerTest.Actions
{
    [TestClass]
    public class Actions_ChangeAction
    {
        [TestMethod]
        public void Constructor_With_Values()
        {
            var changeAction = new ChangeAction("mySender", ElementType.CHANNEL, "myChannel", "propertyName", "newPropertyValue");
            Assert.IsTrue(string.Equals(changeAction.Sender, "mySender"));
            Assert.IsTrue(string.Equals(changeAction.ElementName, "myChannel"));
            Assert.IsTrue(string.Equals(changeAction.ElementProperty, "propertyName"));
            Assert.IsTrue(string.Equals(changeAction.NewElementPropertyValue, "newPropertyValue"));
            Assert.AreEqual(changeAction.ElementType, ElementType.CHANNEL);
            Assert.AreEqual(changeAction.ActionType, ActionType.CHANGE);
        }
    }
}

