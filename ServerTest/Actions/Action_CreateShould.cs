using Microsoft.VisualStudio.TestTools.UnitTesting;
using Server.Actions;
using Server.Elements;

namespace ServerTest.Actions
{
    [TestClass]
    public class Actions_CreateAction
    {
        [TestMethod]
        public void Constructor_With_Values()
        {
            var createAction = new CreateAction("mySender", ElementType.CHANNEL, "myCreatedChannel");
            Assert.IsTrue(string.Equals(createAction.Sender, "mySender"));
            Assert.IsTrue(string.Equals(createAction.ElementName, "myCreatedChannel"));
            Assert.AreEqual(createAction.ElementType, Server.Elements.ElementType.CHANNEL);
            Assert.AreEqual(createAction.ActionType, ActionType.CREATE);
        }

        [TestMethod]
        public void Execute_Action_Create_Channel()
        {
            var createAction = new CreateAction("mySender", ElementType.CHANNEL, "newChannel");
            // learn how to be smarter
        }
    }
}
